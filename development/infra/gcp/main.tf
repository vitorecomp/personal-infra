data "google_client_openid_userinfo" "me" {
  count = var.enable_os_login && var.register_oslogin_ssh_key && trimspace(var.oslogin_user) == "" ? 1 : 0
}

# Fixed SSH client keypair (kept in Terraform state, exported locally to ./ssh-key).
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

# Fixed ED25519 + RSA SSH host keypairs so known_hosts never breaks across restarts
# AND Cloud Console SSH-in-browser (which requires rsa-sha2-256/ssh-rsa) works too.
resource "tls_private_key" "ssh_host_controller" {
  algorithm = "ED25519"
}

resource "tls_private_key" "ssh_host_controller_rsa" {
  algorithm = "RSA"
  rsa_bits  = 3072
}

resource "tls_private_key" "ssh_host_gpu" {
  algorithm = "ED25519"
}

resource "tls_private_key" "ssh_host_gpu_rsa" {
  algorithm = "RSA"
  rsa_bits  = 3072
}

# Dedicated ED25519 SSH keypair used by the Controller VM
# to SSH directly into the GPU VM over the internal VPC (10.10.0.11).
resource "tls_private_key" "controller_to_gpu" {
  algorithm = "ED25519"
}

resource "google_os_login_ssh_public_key" "ssh" {
  count = var.enable_os_login && var.register_oslogin_ssh_key && local.effective_oslogin_email != "" ? 1 : 0

  user = local.effective_oslogin_email
  key  = "${trimspace(tls_private_key.ssh.public_key_openssh)} ${var.ssh_username}"
}

# Dedicated least-privilege Service Account for the Controller VM:
# can ONLY describe/start the GPU VM and SSH into it via instance-level OS Login.
resource "google_service_account" "controller" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-ctrl"
  display_name = "Watchdog controller SA for ${var.name_prefix}-vm"
}

# Dedicated Service Account for the GPU VM so OS Login serviceAccountUser IAM
# is scoped solely to the GPU VM rather than the project-wide default compute SA.
resource "google_service_account" "gpu" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-vm-sa"
  display_name = "Runtime SA for ${var.name_prefix}-vm"
}

locals {
  controller_zone            = trimspace(var.controller_zone) != "" ? trimspace(var.controller_zone) : var.zone
  gpu_vm_name                = "${var.name_prefix}-vm"
  controller_vm_name         = "${var.name_prefix}-controller"
  ssh_public_key             = "${trimspace(tls_private_key.ssh.public_key_openssh)} ${var.ssh_username}"
  controller_gpu_public_key  = "${trimspace(tls_private_key.controller_to_gpu.public_key_openssh)} ${var.name_prefix}-controller"
  controller_to_gpu_ssh_user = var.enable_os_login ? "sa_${google_service_account.controller.unique_id}" : var.ssh_username
  effective_oslogin_email    = trimspace(var.oslogin_user) != "" ? trimspace(var.oslogin_user) : try(coalesce(data.google_client_openid_userinfo.me[0].email, ""), "")
  oslogin_username = local.effective_oslogin_email != "" ? replace(
    lower(local.effective_oslogin_email),
    "/[^a-z0-9]/",
    "_",
  ) : var.ssh_username

  common_ssh_metadata = merge(
    {
      enable-oslogin         = var.enable_os_login ? "TRUE" : "FALSE"
      block-project-ssh-keys = "TRUE"
    },
    var.enable_os_login ? {} : {
      ssh-keys = "${var.ssh_username}:${local.ssh_public_key}"
    }
  )

  # Shared shell helper embedded into both VMs to eliminate duplication while keeping
  # each VM's fixed ED25519 + RSA SSH host keys and local sudo user idempotent.
  common_ssh_bootstrap = <<EOB
install_if_changed() {
  local src="$1" dst="$2" mode="$3"
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    chmod "$mode" "$src"
    mv "$src" "$dst"
    chown root:root "$dst"
    return 0
  fi
  rm -f "$src"
  return 1
}

setup_ssh_host_and_user() {
  local ed_priv="$1"
  local ed_pub="$2"
  local rsa_priv="$3"
  local rsa_pub="$4"

  install -d -m 0755 /etc/ssh /etc/ssh/sshd_config.d
  printf '%s\n' "$ed_priv" > /etc/ssh/ssh_host_ed25519_key.tmp
  printf '%s\n' "$ed_pub" > /etc/ssh/ssh_host_ed25519_key.pub.tmp
  printf '%s\n' "$rsa_priv" > /etc/ssh/ssh_host_rsa_key.tmp
  printf '%s\n' "$rsa_pub" > /etc/ssh/ssh_host_rsa_key.pub.tmp
  printf '%s\n%s\n' "HostKey /etc/ssh/ssh_host_ed25519_key" "HostKey /etc/ssh/ssh_host_rsa_key" > /etc/ssh/sshd_config.d/99-fixed-hostkey.conf.tmp

  local changed=0
  if install_if_changed /etc/ssh/ssh_host_ed25519_key.tmp /etc/ssh/ssh_host_ed25519_key 0600; then changed=1; fi
  if install_if_changed /etc/ssh/ssh_host_ed25519_key.pub.tmp /etc/ssh/ssh_host_ed25519_key.pub 0644; then changed=1; fi
  if install_if_changed /etc/ssh/ssh_host_rsa_key.tmp /etc/ssh/ssh_host_rsa_key 0600; then changed=1; fi
  if install_if_changed /etc/ssh/ssh_host_rsa_key.pub.tmp /etc/ssh/ssh_host_rsa_key.pub 0644; then changed=1; fi
  if install_if_changed /etc/ssh/sshd_config.d/99-fixed-hostkey.conf.tmp /etc/ssh/sshd_config.d/99-fixed-hostkey.conf 0644; then changed=1; fi

  if [ "$changed" -eq 1 ]; then
    mkdir -p /run/sshd
    if sshd -t; then
      systemctl reload-or-restart ssh || systemctl reload-or-restart sshd || true
    fi
  fi

  if ! id -u "${var.ssh_username}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${var.ssh_username}"
  fi
  usermod -aG sudo "${var.ssh_username}"
  echo "${var.ssh_username} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${var.ssh_username}"
  chmod 0440 "/etc/sudoers.d/90-${var.ssh_username}"

  local user_home
  user_home=$(getent passwd "${var.ssh_username}" | cut -d: -f6)
  install -d -m 0700 -o "${var.ssh_username}" -g "${var.ssh_username}" "$user_home/.ssh"
  printf '%s\n' "${local.ssh_public_key}" > "$user_home/.ssh/authorized_keys"
  chown "${var.ssh_username}:${var.ssh_username}" "$user_home/.ssh/authorized_keys"
  chmod 0600 "$user_home/.ssh/authorized_keys"
}
EOB

  controller_startup_script = <<EOF
#!/usr/bin/env bash
set -euo pipefail

${local.common_ssh_bootstrap}

CTRL_HOST_KEY=$(cat <<'KEYEOF'
${trimspace(tls_private_key.ssh_host_controller.private_key_openssh)}
KEYEOF
)
CTRL_HOST_PUB="${trimspace(tls_private_key.ssh_host_controller.public_key_openssh)} ${local.controller_vm_name}-host"
CTRL_RSA_KEY=$(cat <<'RSAKEYEOF'
${trimspace(tls_private_key.ssh_host_controller_rsa.private_key_pem)}
RSAKEYEOF
)
CTRL_RSA_PUB="${trimspace(tls_private_key.ssh_host_controller_rsa.public_key_openssh)} ${local.controller_vm_name}-rsa"
setup_ssh_host_and_user "$CTRL_HOST_KEY" "$CTRL_HOST_PUB" "$CTRL_RSA_KEY" "$CTRL_RSA_PUB"

# Pin the GPU VM host key in system ssh_known_hosts for internal jumps.
printf '%s %s\n%s %s\n' \
  "${google_compute_address.gpu_internal_ip.address}" "${trimspace(tls_private_key.ssh_host_gpu.public_key_openssh)}" \
  "gpu,${local.gpu_vm_name}" "${trimspace(tls_private_key.ssh_host_gpu.public_key_openssh)}" > /etc/ssh/ssh_known_hosts
chmod 0644 /etc/ssh/ssh_known_hosts

# Configure seamless `ssh gpu` / `gpu-ssh` / `gpu-wait-ssh` access from Controller -> GPU VM.
install -d -m 0755 /etc/gpu-ssh /etc/ssh/ssh_config.d /etc/skel/.ssh
chmod 0700 /etc/skel/.ssh
cat <<'CTRLGPUKEYEOF' > /etc/gpu-ssh/id_ed25519
${trimspace(tls_private_key.controller_to_gpu.private_key_openssh)}
CTRLGPUKEYEOF
chmod 0600 /etc/gpu-ssh/id_ed25519
chown root:root /etc/gpu-ssh/id_ed25519
printf '%s\n' "${local.controller_gpu_public_key}" > /etc/gpu-ssh/id_ed25519.pub
chmod 0644 /etc/gpu-ssh/id_ed25519.pub

cp /etc/gpu-ssh/id_ed25519 /etc/skel/.ssh/gpu_ed25519
chmod 0600 /etc/skel/.ssh/gpu_ed25519
mkdir -p /root/.ssh
chmod 0700 /root/.ssh
cp /etc/gpu-ssh/id_ed25519 /root/.ssh/gpu_ed25519
chmod 0600 /root/.ssh/gpu_ed25519
CTRL_LOCAL_HOME=$(getent passwd "${var.ssh_username}" | cut -d: -f6)
cp /etc/gpu-ssh/id_ed25519 "$CTRL_LOCAL_HOME/.ssh/gpu_ed25519"
chown "${var.ssh_username}:${var.ssh_username}" "$CTRL_LOCAL_HOME/.ssh/gpu_ed25519"
chmod 0600 "$CTRL_LOCAL_HOME/.ssh/gpu_ed25519"

# Provision dedicated non-root GitHub Actions runner user, workspace directory, and GPU SSH key.
if ! id -u "${var.runner_username}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${var.runner_username}"
fi
RUNNER_HOME=$(getent passwd "${var.runner_username}" | cut -d: -f6)
install -d -m 0700 -o "${var.runner_username}" -g "${var.runner_username}" "$RUNNER_HOME/.ssh"
cp /etc/gpu-ssh/id_ed25519 "$RUNNER_HOME/.ssh/gpu_ed25519"
chown "${var.runner_username}:${var.runner_username}" "$RUNNER_HOME/.ssh/gpu_ed25519"
chmod 0600 "$RUNNER_HOME/.ssh/gpu_ed25519"
install -d -m 0755 -o "${var.runner_username}" -g "${var.runner_username}" /opt/actions-runner

export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
GPU_SSH_USER="${local.controller_to_gpu_ssh_user}"
if [ "${var.enable_os_login ? "true" : "false"}" = "true" ]; then
  for _ in 1 2 3 4 5; do
    if gcloud compute os-login ssh-keys add --key-file=/etc/gpu-ssh/id_ed25519.pub --project="${var.project_id}" >/dev/null 2>&1; then
      break
    fi
    sleep 3
  done
  DETECTED_SA_USER="$(gcloud compute os-login describe-profile --project="${var.project_id}" --format="value(posixAccounts[0].username)" 2>/dev/null || true)"
  if [ -n "$DETECTED_SA_USER" ]; then
    GPU_SSH_USER="$DETECTED_SA_USER"
  fi
fi

cat <<SSHCONFEOF > /etc/ssh/ssh_config.d/90-gpu.conf
Host gpu ${local.gpu_vm_name}
    HostName ${google_compute_address.gpu_internal_ip.address}
    User $GPU_SSH_USER
    IdentityFile ~/.ssh/gpu_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    GlobalKnownHostsFile /etc/ssh/ssh_known_hosts
    ServerAliveInterval 30
    ServerAliveCountMax 4
SSHCONFEOF
chmod 0644 /etc/ssh/ssh_config.d/90-gpu.conf

cat <<'KEYINSTEOF' > /usr/local/sbin/gpu-install-user-key
#!/usr/bin/env bash
set -euo pipefail
TARGET_USER="$${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || exit 0
KEY_CONTENT="$(cat /etc/gpu-ssh/id_ed25519)"
runuser -u "$TARGET_USER" -- bash -c '
  umask 077
  mkdir -p "$HOME/.ssh"
  printf "%s\n" "$1" > "$HOME/.ssh/gpu_ed25519"
' _ "$KEY_CONTENT"
KEYINSTEOF
chmod 0755 /usr/local/sbin/gpu-install-user-key
chown root:root /usr/local/sbin/gpu-install-user-key
echo 'ALL ALL=(root) NOPASSWD: /usr/local/sbin/gpu-install-user-key ""' > /etc/sudoers.d/91-gpu-ssh-key
chmod 0440 /etc/sudoers.d/91-gpu-ssh-key

cat <<'PROFEOF' > /etc/profile.d/gpu-ssh.sh
if [ "$(id -u)" -ne 0 ] && [ -n "$${HOME:-}" ] && [ ! -f "$HOME/.ssh/gpu_ed25519" ]; then
  sudo -n /usr/local/sbin/gpu-install-user-key >/dev/null 2>&1 || true
fi
PROFEOF
chmod 0644 /etc/profile.d/gpu-ssh.sh

cat <<'GPUSSHEOF' > /usr/local/bin/gpu-ssh
#!/usr/bin/env bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ] && [ ! -f "$HOME/.ssh/gpu_ed25519" ]; then
  sudo -n /usr/local/sbin/gpu-install-user-key
fi
exec ssh gpu "$@"
GPUSSHEOF
chmod 0755 /usr/local/bin/gpu-ssh

cat <<'GPUWAITEOF' > /usr/local/bin/gpu-wait-ssh
#!/usr/bin/env bash
set -euo pipefail
TIMEOUT_SEC="$${1:-600}"
DEADLINE=$((SECONDS + TIMEOUT_SEC))
while (( SECONDS < DEADLINE )); do
  if /usr/local/bin/gpu-ssh -o ConnectTimeout=5 -o BatchMode=yes true >/dev/null 2>&1; then
    echo "GPU VM SSH is ready."
    exit 0
  fi
  sleep 5
done
echo "Timed out after $${TIMEOUT_SEC}s waiting for GPU VM SSH." >&2
exit 1
GPUWAITEOF
chmod 0755 /usr/local/bin/gpu-wait-ssh

# Install the systemd watchdog that automatically restarts the Spot GPU VM whenever
# it enters TERMINATED/STOPPED and keeps retrying until Spot capacity returns.
cat <<'ENVEOF' > /etc/default/gpu-watchdog
PROJECT_ID="${var.project_id}"
VM_NAME="${local.gpu_vm_name}"
VM_ZONE="${var.zone}"
POLL_INTERVAL_SEC="${var.watchdog_poll_interval_sec}"
RETRY_INTERVAL_SEC="${var.watchdog_retry_interval_sec}"
ENVEOF
chmod 0644 /etc/default/gpu-watchdog

cat <<'WATCHDOGEOF' > /usr/local/bin/gpu-watchdog.sh
#!/usr/bin/env bash
set -u

export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
source /etc/default/gpu-watchdog
PAUSE_FILE="/etc/gpu-watchdog.paused"

log() {
  echo "[$(date -Is)] [gpu-watchdog] $*"
}

while true; do
  if [[ -f "$PAUSE_FILE" ]]; then
    log "Paused ($PAUSE_FILE exists); skipping check."
    sleep "$POLL_INTERVAL_SEC"
    continue
  fi

  STATUS=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" \
    --project="$PROJECT_ID" \
    --format="value(status)" 2>&1 || true)

  case "$STATUS" in
    RUNNING)
      sleep "$POLL_INTERVAL_SEC"
      ;;
    TERMINATED|STOPPED)
      log "VM $VM_NAME in $VM_ZONE is $STATUS; issuing start (--async)..."
      if OUT=$(gcloud compute instances start "$VM_NAME" \
        --zone="$VM_ZONE" \
        --project="$PROJECT_ID" \
        --async 2>&1); then
        log "Start requested for $VM_NAME: $OUT"
      else
        log "Start attempt failed (will retry in $${RETRY_INTERVAL_SEC}s): $OUT"
      fi
      sleep "$RETRY_INTERVAL_SEC"
      ;;
    SUSPENDED)
      log "VM $VM_NAME is SUSPENDED; issuing resume (--async)..."
      gcloud compute instances resume "$VM_NAME" \
        --zone="$VM_ZONE" \
        --project="$PROJECT_ID" \
        --async 2>&1 || true
      sleep "$RETRY_INTERVAL_SEC"
      ;;
    PROVISIONING|STAGING|STOPPING|REPAIRING|DEPROVISIONING)
      log "VM $VM_NAME in transitional state: $STATUS"
      sleep "$POLL_INTERVAL_SEC"
      ;;
    *)
      log "Unexpected describe output for $VM_NAME: $STATUS (retrying in $${RETRY_INTERVAL_SEC}s)"
      sleep "$RETRY_INTERVAL_SEC"
      ;;
  esac
done
WATCHDOGEOF
chmod 0755 /usr/local/bin/gpu-watchdog.sh

cat <<'STATUSEOF' > /usr/local/bin/gpu-status
#!/usr/bin/env bash
export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
source /etc/default/gpu-watchdog
echo "=== GPU VM Status ==="
gcloud compute instances describe "$VM_NAME" --zone="$VM_ZONE" --project="$PROJECT_ID" \
  --format="table(name,zone.basename(),status,scheduling.provisioningModel,networkInterfaces[0].networkIP)"
echo "=== Watchdog Service ==="
systemctl status gpu-watchdog.service --no-pager -n 10 || true
STATUSEOF
chmod 0755 /usr/local/bin/gpu-status

cat <<'PAUSEEOF' > /usr/local/bin/gpu-pause
#!/usr/bin/env bash
sudo touch /etc/gpu-watchdog.paused
echo "Paused gpu-watchdog (/etc/gpu-watchdog.paused created)."
PAUSEEOF
chmod 0755 /usr/local/bin/gpu-pause

cat <<'RESUMEEOF' > /usr/local/bin/gpu-resume
#!/usr/bin/env bash
sudo rm -f /etc/gpu-watchdog.paused
echo "Resumed gpu-watchdog (/etc/gpu-watchdog.paused removed)."
RESUMEEOF
chmod 0755 /usr/local/bin/gpu-resume

cat <<'SVCEOF' > /etc/systemd/system/gpu-watchdog.service
[Unit]
Description=Watchdog that automatically restarts Spot GPU VM on preemption
After=network-online.target snapd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gpu-watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now gpu-watchdog.service
systemctl restart gpu-watchdog.service

# Pre-install all OS and .NET runtime dependencies required by the GitHub Actions
# self-hosted runner (`config.sh` / `Runner.Listener`) and GPU sync workflows.
RUNNER_PACKAGES=(
  ca-certificates
  curl
  git
  git-lfs
  jq
  libicu-dev
  libkrb5-3
  libssl-dev
  rsync
  tar
  unzip
  xz-utils
  zip
  zlib1g
)
if ! dpkg -s "$${RUNNER_PACKAGES[@]}" >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  for _ in 1 2 3; do
    if apt-get -o DPkg::Lock::Timeout=120 update -qq && \
       apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends "$${RUNNER_PACKAGES[@]}"; then
      break
    fi
    sleep 5
  done
  git lfs install --system >/dev/null 2>&1 || true
fi

# Pre-stage the latest GitHub Actions runner binary into /opt/actions-runner (without registering)
# and run GitHub's dependency verifier so `config.sh` can run immediately later.
if [ ! -x /opt/actions-runner/config.sh ]; then
  RUNNER_LATEST_URL="$(curl -fsSLI -o /dev/null -w '%%{url_effective}' https://github.com/actions/runner/releases/latest || true)"
  RUNNER_VER="$${RUNNER_LATEST_URL##*/v}"
  if [[ -n "$RUNNER_VER" && "$RUNNER_VER" != "$RUNNER_LATEST_URL" ]]; then
    TMP_TAR="$(mktemp /tmp/actions-runner.XXXXXX.tar.gz)"
    if curl -fsSL "https://github.com/actions/runner/releases/download/v$${RUNNER_VER}/actions-runner-linux-x64-$${RUNNER_VER}.tar.gz" -o "$TMP_TAR"; then
      tar -xzf "$TMP_TAR" -C /opt/actions-runner
      chown -R "${var.runner_username}:${var.runner_username}" /opt/actions-runner
      /opt/actions-runner/bin/installdependencies.sh >/dev/null 2>&1 || true
    fi
    rm -f "$TMP_TAR"
  fi
fi
EOF

  gpu_startup_script = <<EOF
#!/usr/bin/env bash
set -euo pipefail

${local.common_ssh_bootstrap}

GPU_HOST_KEY=$(cat <<'KEYEOF'
${trimspace(tls_private_key.ssh_host_gpu.private_key_openssh)}
KEYEOF
)
GPU_HOST_PUB="${trimspace(tls_private_key.ssh_host_gpu.public_key_openssh)} ${local.gpu_vm_name}-host"
GPU_RSA_KEY=$(cat <<'RSAKEYEOF'
${trimspace(tls_private_key.ssh_host_gpu_rsa.private_key_pem)}
RSAKEYEOF
)
GPU_RSA_PUB="${trimspace(tls_private_key.ssh_host_gpu_rsa.public_key_openssh)} ${local.gpu_vm_name}-rsa"
setup_ssh_host_and_user "$GPU_HOST_KEY" "$GPU_HOST_PUB" "$GPU_RSA_KEY" "$GPU_RSA_PUB"

# Also authorize the Controller VM's key for local ssh_username when OS Login is disabled.
GPU_LOCAL_HOME=$(getent passwd "${var.ssh_username}" | cut -d: -f6)
if ! grep -qxF "${local.controller_gpu_public_key}" "$GPU_LOCAL_HOME/.ssh/authorized_keys" 2>/dev/null; then
  printf '%s\n' "${local.controller_gpu_public_key}" >> "$GPU_LOCAL_HOME/.ssh/authorized_keys"
  chown "${var.ssh_username}:${var.ssh_username}" "$GPU_LOCAL_HOME/.ssh/authorized_keys"
  chmod 0600 "$GPU_LOCAL_HOME/.ssh/authorized_keys"
fi

# Format once (if unformatted) and mount the persistent Hyperdisk data volume at /mnt/data.
# Preserved intact across Spot preemptions and controller restarts.
DATA_DISK="/dev/disk/by-id/google-data"
MOUNT_POINT="/mnt/data"
if [ -b "$DATA_DISK" ]; then
  mkdir -p "$MOUNT_POINT"
  if ! blkid "$DATA_DISK" >/dev/null 2>&1; then
    mkfs.ext4 -F -m 0 -E lazy_itable_init=1,lazy_journal_init=1,nodiscard "$DATA_DISK"
  fi
  if ! mountpoint -q "$MOUNT_POINT"; then
    mount -o discard,defaults "$DATA_DISK" "$MOUNT_POINT"
  fi
  UUID=$(blkid -s UUID -o value "$DATA_DISK")
  if [ -n "$UUID" ] && ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNT_POINT ext4 discard,defaults,nofail 0 2" >> /etc/fstab
  fi
  chown "${var.ssh_username}:${var.ssh_username}" "$MOUNT_POINT"
  chmod 1777 "$MOUNT_POINT"
fi
EOF

  gpu_shutdown_script = <<EOF
#!/usr/bin/env bash
sync
if mountpoint -q /mnt/data; then
  umount -f /mnt/data || true
fi
EOF
}

# Small always-on STANDARD controller + bastion VM owning a fixed external IP
# and automatically restarting the Spot GPU VM whenever it stops.
resource "google_compute_instance" "controller" {
  project                   = var.project_id
  name                      = local.controller_vm_name
  machine_type              = var.controller_machine_type
  zone                      = local.controller_zone
  tags                      = ["${var.name_prefix}-ssh"]
  labels                    = var.labels
  allow_stopping_for_update = true

  boot_disk {
    auto_delete = true
    initialize_params {
      image = var.boot_image
      type  = var.controller_disk_type
      size  = var.controller_disk_size_gb
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    network_ip = google_compute_address.controller_internal_ip.address

    dynamic "access_config" {
      for_each = var.enable_external_ip ? [1] : []
      content {
        nat_ip       = google_compute_address.external_ip[0].address
        network_tier = "PREMIUM"
      }
    }
  }

  scheduling {
    on_host_maintenance = "MIGRATE"
    automatic_restart   = true
    provisioning_model  = "STANDARD"
  }

  shielded_instance_config {
    enable_secure_boot          = var.enable_shielded_vm
    enable_vtpm                 = var.enable_shielded_vm
    enable_integrity_monitoring = var.enable_shielded_vm
  }

  metadata = merge(
    local.common_ssh_metadata,
    {
      startup-script = local.controller_startup_script
    }
  )

  service_account {
    email  = google_service_account.controller.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  lifecycle {
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }

  depends_on = [google_compute_router_nat.nat]
}

# Persistent Hyperdisk Balanced data volume surviving Spot STOP preemptions.
resource "google_compute_disk" "gpu_data" {
  project                = var.project_id
  name                   = "${var.name_prefix}-data"
  zone                   = var.zone
  type                   = var.data_disk_type
  size                   = var.data_disk_size_gb
  provisioned_iops       = var.data_disk_iops
  provisioned_throughput = var.data_disk_throughput_mbps
  labels                 = var.labels
}

# Development GPU VM (`g4-standard-192` by default) managed by the controller watchdog.
resource "google_compute_instance" "gpu_vm" {
  project                   = var.project_id
  name                      = local.gpu_vm_name
  machine_type              = var.machine_type
  zone                      = var.zone
  tags                      = ["${var.name_prefix}-vm"]
  labels                    = var.labels
  allow_stopping_for_update = true

  boot_disk {
    auto_delete = true
    initialize_params {
      image                  = var.boot_image
      type                   = var.boot_disk_type
      size                   = var.boot_disk_size_gb
      provisioned_iops       = var.boot_disk_iops
      provisioned_throughput = var.boot_disk_throughput_mbps
    }
  }

  attached_disk {
    source      = google_compute_disk.gpu_data.id
    device_name = "data"
    mode        = "READ_WRITE"
  }

  # Fixed internal IP + optional fixed static external IP (survives Spot STOP/start).
  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    nic_type   = "GVNIC"
    network_ip = google_compute_address.gpu_internal_ip.address

    dynamic "access_config" {
      for_each = var.enable_external_ip ? [1] : []
      content {
        nat_ip       = google_compute_address.gpu_external_ip[0].address
        network_tier = "PREMIUM"
      }
    }
  }

  scheduling {
    on_host_maintenance         = "TERMINATE"
    automatic_restart           = var.provisioning_model == "STANDARD"
    preemptible                 = var.provisioning_model == "SPOT"
    provisioning_model          = var.provisioning_model
    instance_termination_action = var.provisioning_model == "SPOT" ? "STOP" : null
  }

  shielded_instance_config {
    enable_secure_boot          = var.enable_shielded_vm
    enable_vtpm                 = var.enable_shielded_vm
    enable_integrity_monitoring = var.enable_shielded_vm
  }

  metadata = merge(
    local.common_ssh_metadata,
    var.enable_os_login ? {} : {
      ssh-keys = "${var.ssh_username}:${local.ssh_public_key}\n${var.ssh_username}:${local.controller_gpu_public_key}"
    },
    {
      startup-script  = local.gpu_startup_script
      shutdown-script = local.gpu_shutdown_script
    }
  )

  service_account {
    email  = google_service_account.gpu.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  # Fail fast (2m instead of 20m) when GCE creates the Spot VM in TERMINATED state
  # during a stockout so deployment scripts can try other zones or hand off to gpu-watchdog.
  timeouts {
    create = "2m"
    update = "5m"
    delete = "5m"
  }

  lifecycle {
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }

  depends_on = [google_compute_router_nat.nat]
}

# Grant Controller SA permission ONLY on the specific GPU VM instance:
# 1. compute.instanceAdmin.v1 so gpu-watchdog can describe/start the Spot GPU VM
# 2. compute.osAdminLogin + iam.serviceAccountUser (on GPU SA only) so the Controller VM
#    can SSH (`ssh gpu` / `gpu-ssh`) with sudo into the GPU VM.
resource "google_compute_instance_iam_member" "controller_gpu_admin" {
  project       = var.project_id
  zone          = google_compute_instance.gpu_vm.zone
  instance_name = google_compute_instance.gpu_vm.name
  role          = "roles/compute.instanceAdmin.v1"
  member        = "serviceAccount:${google_service_account.controller.email}"
}

resource "google_compute_instance_iam_member" "controller_gpu_oslogin" {
  project       = var.project_id
  zone          = google_compute_instance.gpu_vm.zone
  instance_name = google_compute_instance.gpu_vm.name
  role          = "roles/compute.osAdminLogin"
  member        = "serviceAccount:${google_service_account.controller.email}"
}

resource "google_service_account_iam_member" "controller_gpu_sa_user" {
  service_account_id = google_service_account.gpu.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.controller.email}"
}
