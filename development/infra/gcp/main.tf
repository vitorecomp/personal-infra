# Dedicated least-privilege Service Account for the GPU MIG instances.
resource "google_service_account" "gpu" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-vm-sa"
  display_name = "Runtime SA for ${var.name_prefix}-mig GPU instances"
}

locals {
  effective_zones = length(var.zones) > 0 ? [
    for z in var.zones : trimspace(z) if trimspace(z) != ""
  ] : (trimspace(var.zone) != "" ? [trimspace(var.zone)] : [])

  effective_cache_bucket_name = trim(
    lower(
      trimspace(var.cache_bucket_name) != "" ? trimspace(var.cache_bucket_name) : substr(
        replace(lower("${var.project_id}-${var.name_prefix}-cache-${var.region}"), "/[^a-z0-9-]/", "-"),
        0,
        63
      )
    ),
    "-"
  )

  effective_runner_name = trimspace(var.runner_name) != "" ? trimspace(var.runner_name) : "${var.name_prefix}-runner"

  # MIG autohealing needs the probe reachable from Google's health checkers, i.e. firewall rules managed here.
  autohealing_enabled = var.enable_autohealing && var.enable_ingress_firewalls
  # gpu-health: always healthy for the first 30 min of a boot (driver install + reboot happen before the runner starts);
  # after that, healthy only while the GitHub Actions runner service is active.
  health_boot_grace_sec = 1800
  # Boot hook (step 9): GCS restore of the model (~20 min) + image builds + vLLM load (deploy waits up to 90 min).
  boot_hook_timeout_sec = 10800
  create_runner_secret_version = (
    trimspace(var.github_repo) != "" &&
    (trimspace(var.runner_token) != "" || trimspace(var.runner_pat) != "")
  )

  gpu_startup_script = <<EOF
#!/usr/bin/env bash
# Failsafe by design: best-effort, NOT `set -e`/`set -u`. A failing step is logged (ERR trap, with its line) and the
# script carries on towards the runner, which is the only thing that matters here; every network call has a timeout.
# Only a machine fault a fresh VM may not have (no data disk, format/mount failure) stops it: fatal() also makes
# gpu-health report unhealthy at once, so autohealing replaces the VM without waiting out the boot grace.
set -o pipefail

mkdir -p /var/log
exec > >(tee -a /var/log/gpu-mig-bootstrap.log) 2>&1
trap 'echo "[error] startup step failed (continuing) at line $LINENO: $BASH_COMMAND" >&2' ERR
fatal() {
  echo "[fatal] $*; gpu-health now reports unhealthy so the MIG replaces this VM." >&2
  printf '%s\n' "$*" > /run/gpu-health-fatal
  exit 1
}
export HOME="$${HOME:-/root}"
export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

echo "=== [gpu-mig-bootstrap] Starting at $(date -Is) ==="

# 0. Host probe for MIG autohealing: gpu-health answers GET /health on 0.0.0.0:${var.health_check_port}, which the firewall
#    opens only to Google's health checkers. Healthy for the first 30 min of a boot; then only while the GitHub Actions
#    runner service is active. It checks the runner only, never the containers: a stack/model that fails to start is a
#    config problem (deploy_gpu_stack.sh reports it), and recreating the VM for it would only loop.
#    Installed first and enabled, so a boot that hangs before the runner starts (or a VM that stops answering, or a
#    runner that dies) gets the VM recreated.
if [ "${local.autohealing_enabled}" = "true" ]; then
  cat <<'HEALTHEOF' > /usr/local/bin/gpu-health
#!/usr/bin/env python3
"""GCE MIG autohealing probe for the GPU VM (personal-infra, development/infra/gcp/main.tf)."""
import http.server
import os
import pathlib
import subprocess

PORT = int(os.environ.get("GPU_HEALTH_PORT", "8090"))
GRACE_S = int(os.environ.get("GPU_HEALTH_BOOT_GRACE_S", "1800"))
FATAL = pathlib.Path("/run/gpu-health-fatal")
RUNNER_SERVICE_FILE = pathlib.Path("/mnt/data/actions-runner/.service")
FALLBACK_SERVICE = "actions.runner.gpu.service"


def uptime_s() -> float:
    return float(pathlib.Path("/proc/uptime").read_text().split()[0])


def runner_active() -> bool:
    names = [FALLBACK_SERVICE]
    try:
        names.insert(0, RUNNER_SERVICE_FILE.read_text().strip())
    except OSError:
        pass
    return any(n and subprocess.run(["systemctl", "is-active", "--quiet", n], timeout=5).returncode == 0 for n in names)


def status() -> tuple:
    if FATAL.exists():
        return 503, "fatal: " + FATAL.read_text().strip()[:200]
    if runner_active():
        return 200, "ok"
    if uptime_s() < GRACE_S:
        return 200, "booting"
    return 503, "runner service inactive"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        try:
            code, msg = status() if self.path.split("?")[0] == "/health" else (404, "not found")
        except Exception as exc:  # a probe that cannot decide reports unhealthy
            code, msg = 503, type(exc).__name__
        body = (msg + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
HEALTHEOF
  chmod 0755 /usr/local/bin/gpu-health
  cat <<HEALTHUNIT > /etc/systemd/system/gpu-health.service
[Unit]
Description=Host probe for GCE MIG autohealing (personal-infra)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/gpu-health
Environment=GPU_HEALTH_PORT=${var.health_check_port}
Environment=GPU_HEALTH_BOOT_GRACE_S=${local.health_boot_grace_sec}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
HEALTHUNIT
  systemctl daemon-reload
  systemctl enable gpu-health.service >/dev/null 2>&1 || true
  systemctl restart gpu-health.service || echo "[warn] Failed to start gpu-health.service."
else
  systemctl disable --now gpu-health.service >/dev/null 2>&1 || true
fi

# 1. Wait for, format once (if unformatted), and mount the ephemeral Hyperdisk data volume at /mnt/data.
DATA_DISK="/dev/disk/by-id/google-data"
MOUNT_POINT="/mnt/data"
for _ in $(seq 1 30); do
  if [ -b "$DATA_DISK" ]; then
    break
  fi
  sleep 1
done

if [ ! -b "$DATA_DISK" ]; then
  fatal "ephemeral data disk $DATA_DISK not found (not filling the boot disk instead)"
fi

mkdir -p "$MOUNT_POINT"
if ! blkid "$DATA_DISK" >/dev/null 2>&1; then
  echo "[bootstrap] Formatting $DATA_DISK as ext4..."
  mkfs.ext4 -F -m 0 -E lazy_itable_init=1,lazy_journal_init=1,nodiscard "$DATA_DISK" || fatal "mkfs.ext4 $DATA_DISK failed"
fi
if ! mountpoint -q "$MOUNT_POINT"; then
  mount -o discard,defaults "$DATA_DISK" "$MOUNT_POINT" || fatal "mount $DATA_DISK $MOUNT_POINT failed"
fi
mountpoint -q "$MOUNT_POINT" || fatal "$MOUNT_POINT is not a mountpoint"

UUID="$(blkid -s UUID -o value "$DATA_DISK")"
if [ -n "$UUID" ] && ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID $MOUNT_POINT ext4 discard,defaults,nofail 0 2" >> /etc/fstab
fi
chmod 1777 "$MOUNT_POINT"

# Scope: this script only brings the machine up and makes the GitHub Actions runner operational (probe, data disk,
# runner user + packages, GPU driver, runner). Everything else (Podman, NVIDIA container toolkit / CDI, GCS restores
# and sync, the stack itself, log shipping) belongs to the runner: development/scripts/deploy_gpu_stack.sh, run by the
# pipeline and, at boot, by the failsafe boot hook in step 9. So changing the stack never needs deploy.sh.

# 2. Runner directory on /mnt/data.
mkdir -p /mnt/data/actions-runner

# 3. Provision local runner user with passwordless sudo and symlink /opt/actions-runner -> /mnt/data/actions-runner.
RUNNER_USER="${var.runner_username}"
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$RUNNER_USER"
fi
usermod -aG sudo "$RUNNER_USER" || true
echo "$RUNNER_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$RUNNER_USER"
chmod 0440 "/etc/sudoers.d/90-$RUNNER_USER"
chown -R "$RUNNER_USER:$RUNNER_USER" /mnt/data/actions-runner
if [ -d /opt/actions-runner ] && [ ! -L /opt/actions-runner ]; then
  rm -rf /opt/actions-runner
fi
ln -sfn /mnt/data/actions-runner /opt/actions-runner

# 4. Install the OS packages the GitHub Actions runner needs (Podman & co. are installed by the deploy).
HOST_PACKAGES=(
  ca-certificates
  curl
  git
  git-lfs
  gpg
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
dpkg --configure -a >/dev/null 2>&1 || true
if ! dpkg -s "$${HOST_PACKAGES[@]}" >/dev/null 2>&1; then
  echo "[bootstrap] Installing OS and runner packages..."
  for _ in 1 2 3; do
    if apt-get -o DPkg::Lock::Timeout=180 update -qq && \
       apt-get -o DPkg::Lock::Timeout=180 install -y -qq --no-install-recommends "$${HOST_PACKAGES[@]}"; then
      break
    fi
    sleep 5
  done
fi
git lfs install --system >/dev/null 2>&1 || true

# 5. Install Canonical's Secure-Boot-signed NVIDIA open kernel GPU driver (here, not in the deploy: it can need a
# reboot, which would kill a runner job). The container toolkit and CDI spec are the deploy's job.
# Note: GCE Ubuntu 24.04 uses HWE linux-gcp (e.g. 7.0.x-gcp), where Canonical provides prebuilt,
# Secure-Boot-signed open kernel modules (`linux-modules-nvidia-*-open-$(uname -r)`) that load via
# modprobe immediately without DKMS build failures.
if ! nvidia-smi >/dev/null 2>&1; then
  echo "[bootstrap] Installing Ubuntu prebuilt NVIDIA Open Kernel GPU driver for kernel $(uname -r)..."
  apt-get -o DPkg::Lock::Timeout=180 update -qq || true
  if apt-get -o DPkg::Lock::Timeout=180 install -y -qq --no-install-recommends ubuntu-drivers-common; then
    OPEN_DRV="$(ubuntu-drivers list --gpgpu 2>/dev/null | tr ',' '\n' | grep -Eo 'nvidia-driver-[0-9]+(-server)?-open' | sort -V | tail -n 1 || true)"
    if [ -n "$OPEN_DRV" ]; then
      DRV_SUFFIX="$${OPEN_DRV#nvidia-driver-}"
      KMOD_PKG="linux-modules-nvidia-$${DRV_SUFFIX}-$(uname -r)"
      echo "[bootstrap] Installing $OPEN_DRV and signed kernel module $KMOD_PKG..."
      apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$OPEN_DRV" "$KMOD_PKG" || \
        apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$OPEN_DRV" || \
        ubuntu-drivers install --gpgpu || true
    else
      ubuntu-drivers install --gpgpu || ubuntu-drivers install || echo "[warn] ubuntu-drivers install returned non-zero."
    fi
  else
    echo "[warn] Failed to install ubuntu-drivers-common; continuing bootstrap."
  fi
  modprobe nvidia nvidia-uvm nvidia-modeset || true
fi

# Reboot once if NVIDIA kernel modules require booting into the newly installed kernel/driver
# before starting the GitHub Actions runner (guarded by /var/lib/gpu-driver-reboot-attempted).
if ! nvidia-smi >/dev/null 2>&1 && [ ! -f /var/lib/gpu-driver-reboot-attempted ]; then
  mkdir -p /var/lib
  touch /var/lib/gpu-driver-reboot-attempted
  sync
  echo "[bootstrap] Rebooting once to activate NVIDIA kernel modules before starting runner..."
  systemctl reboot
  exit 0
fi

# 6. Tell the runner (and the boot hook) which regional GCS cache bucket belongs to this VM. Never print the name in
#    CI logs: it embeds the GCP project ID.
CACHE_BUCKET="${google_storage_bucket.gpu_cache.name}"
cat <<'CACHEEOF' > /etc/gpu-cache-bucket
CACHE_BUCKET="${google_storage_bucket.gpu_cache.name}"
CACHEEOF
chmod 0644 /etc/gpu-cache-bucket

# 7. Unpack latest GitHub Actions runner binary into /mnt/data/actions-runner if not already present.
RUNNER_DIR="/mnt/data/actions-runner"
if [ ! -x "$RUNNER_DIR/config.sh" ]; then
  echo "[bootstrap] Downloading latest actions-runner-linux-x64 into $RUNNER_DIR..."
  RUNNER_LATEST_URL="$(curl -fsSLI --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 -o /dev/null -w '%%{url_effective}' https://github.com/actions/runner/releases/latest || true)"
  RUNNER_VER="$${RUNNER_LATEST_URL##*/v}"
  if [[ -n "$RUNNER_VER" && "$RUNNER_VER" != "$RUNNER_LATEST_URL" ]]; then
    TMP_TAR="$(mktemp /tmp/actions-runner.XXXXXX.tar.gz)"
    if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 "https://github.com/actions/runner/releases/download/v$${RUNNER_VER}/actions-runner-linux-x64-$${RUNNER_VER}.tar.gz" -o "$TMP_TAR"; then
      tar -xzf "$TMP_TAR" -C "$RUNNER_DIR"
      chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
    else
      echo "[warn] Failed to download actions-runner v$${RUNNER_VER}."
    fi
    rm -f "$TMP_TAR"
  else
    echo "[warn] Could not resolve latest actions-runner release version."
  fi
fi
if [ -x "$RUNNER_DIR/bin/installdependencies.sh" ]; then
  "$RUNNER_DIR/bin/installdependencies.sh" >/dev/null 2>&1 || true
fi

# 8. Restore persisted runner state from GCS (if present), then start or self-register the GitHub Actions runner.
if command -v gcloud >/dev/null 2>&1 && [ -n "$CACHE_BUCKET" ]; then
  echo "[bootstrap] Checking gs://$CACHE_BUCKET/actions-runner-state/ for preserved runner credentials..."
  for rf in .runner .credentials .credentials_rsaparams .env .path svc.sh runsvc.sh; do
    if [ ! -f "$RUNNER_DIR/$rf" ]; then
      if timeout 120 gcloud storage cp "gs://$CACHE_BUCKET/actions-runner-state/$rf" "$RUNNER_DIR/$rf" >/dev/null 2>&1; then
        chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR/$rf"
        case "$rf" in
          *.sh) chmod 0755 "$RUNNER_DIR/$rf" || true ;;
          *) chmod 0600 "$RUNNER_DIR/$rf" || true ;;
        esac
      fi
    fi
  done
fi

SECRET_ID="${google_secret_manager_secret.runner_bootstrap.secret_id}"
PROJECT_ID="${var.project_id}"
BOOTSTRAP_JSON=""
LAST_SM_ERR=""
for _ in 1 2 3 4 5; do
  if command -v gcloud >/dev/null 2>&1; then
    SM_ERR_FILE="$(mktemp /tmp/sm-err.XXXXXX)"
    BOOTSTRAP_JSON="$(timeout 60 gcloud secrets versions access latest \
      --secret="$SECRET_ID" \
      --project="$PROJECT_ID" 2>"$SM_ERR_FILE" || true)"
    if [ -n "$BOOTSTRAP_JSON" ] && ! printf '%s' "$BOOTSTRAP_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
      BOOTSTRAP_JSON=""
    fi
    if [ -z "$BOOTSTRAP_JSON" ]; then
      LAST_SM_ERR="$(tr '\n' ' ' < "$SM_ERR_FILE" | head -c 300 || true)"
    fi
    rm -f "$SM_ERR_FILE"
  fi
  if [ -z "$BOOTSTRAP_JSON" ]; then
    ACCESS_TOKEN="$(curl -fsSL --max-time 15 -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" 2>/dev/null \
      | jq -r '.access_token // empty' 2>/dev/null || true)"
    if [ -z "$ACCESS_TOKEN" ] && [ -f /run/google-mds-mtls/root.crt ] && [ -f /run/google-mds-mtls/client.key ]; then
      CERT_ARG="/run/google-mds-mtls/client.key"
      [ -f /run/google-mds-mtls/client.crt ] && CERT_ARG="/run/google-mds-mtls/client.crt"
      ACCESS_TOKEN="$(curl -fsSL --max-time 15 \
        --cacert /run/google-mds-mtls/root.crt \
        --cert "$CERT_ARG" \
        --key /run/google-mds-mtls/client.key \
        -H "Metadata-Flavor: Google" \
        "https://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token" 2>/dev/null \
        | jq -r '.access_token // empty' 2>/dev/null || true)"
    fi
    if [ -n "$ACCESS_TOKEN" ]; then
      SM_HTTP_FILE="$(mktemp /tmp/sm-http.XXXXXX)"
      SM_CODE="$(curl -sSL --max-time 30 -o "$SM_HTTP_FILE" -w '%%{http_code}' \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/$SECRET_ID/versions/latest:access" 2>/dev/null || true)"
      if [ "$SM_CODE" != "200" ] && [ -f /run/google-mds-mtls/client.key ]; then
        CERT_ARG="/run/google-mds-mtls/client.key"
        [ -f /run/google-mds-mtls/client.crt ] && CERT_ARG="/run/google-mds-mtls/client.crt"
        SM_CODE="$(curl -sSL --max-time 30 -o "$SM_HTTP_FILE" -w '%%{http_code}' \
          --cert "$CERT_ARG" \
          --key /run/google-mds-mtls/client.key \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          "https://secretmanager.mtls.googleapis.com/v1/projects/$PROJECT_ID/secrets/$SECRET_ID/versions/latest:access" 2>/dev/null || true)"
      fi
      if [ "$SM_CODE" = "200" ]; then
        SECRET_B64="$(jq -r '.payload.data // empty' < "$SM_HTTP_FILE" 2>/dev/null || true)"
        if [ -n "$SECRET_B64" ]; then
          BOOTSTRAP_JSON="$(printf '%s' "$SECRET_B64" | base64 -d 2>/dev/null || true)"
        fi
      else
        LAST_SM_ERR="HTTP $SM_CODE: $(jq -r '.error.message // empty' < "$SM_HTTP_FILE" 2>/dev/null || head -c 200 "$SM_HTTP_FILE")"
      fi
      rm -f "$SM_HTTP_FILE"
      unset ACCESS_TOKEN SECRET_B64 SM_CODE
    fi
  fi
  if [ -n "$BOOTSTRAP_JSON" ]; then
    break
  fi
  sleep 3
done
if [ -z "$BOOTSTRAP_JSON" ]; then
  echo "[warn] Could not read Secret Manager bootstrap secret '$SECRET_ID' in '$PROJECT_ID': $LAST_SM_ERR"
fi

GITHUB_REPO=""
RUNNER_NAME=""
RUNNER_LABELS=""
RUNNER_TOKEN=""
RUNNER_PAT=""
if [ -n "$BOOTSTRAP_JSON" ]; then
  GITHUB_REPO="$(printf '%s' "$BOOTSTRAP_JSON" | jq -r '.github_repo // empty' 2>/dev/null || true)"
  RUNNER_NAME="$(printf '%s' "$BOOTSTRAP_JSON" | jq -r '.runner_name // empty' 2>/dev/null || true)"
  RUNNER_LABELS="$(printf '%s' "$BOOTSTRAP_JSON" | jq -r '.runner_labels // empty' 2>/dev/null || true)"
  RUNNER_TOKEN="$(printf '%s' "$BOOTSTRAP_JSON" | jq -r '.runner_token // empty' 2>/dev/null || true)"
  RUNNER_PAT="$(printf '%s' "$BOOTSTRAP_JSON" | jq -r '.runner_pat // empty' 2>/dev/null || true)"
fi

EXISTING_GH_URL=""
EXISTING_AGENT_NAME=""
if [ -f "$RUNNER_DIR/.runner" ] && [ -f "$RUNNER_DIR/.credentials" ]; then
  EXISTING_GH_URL="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("gitHubUrl", ""))' "$RUNNER_DIR/.runner" 2>/dev/null || true)"
  EXISTING_AGENT_NAME="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("agentName", ""))' "$RUNNER_DIR/.runner" 2>/dev/null || true)"
fi

EXPECTED_GH_URL=""
if [ -n "$GITHUB_REPO" ]; then
  EXPECTED_GH_URL="https://github.com/$GITHUB_REPO"
fi
EXISTING_GH_NORM="$(printf '%s' "$EXISTING_GH_URL" | tr '[:upper:]' '[:lower:]' | sed 's:/*$::')"
EXPECTED_GH_NORM="$(printf '%s' "$EXPECTED_GH_URL" | tr '[:upper:]' '[:lower:]' | sed 's:/*$::')"

REUSE_EXISTING=false
if [ -f "$RUNNER_DIR/.runner" ] && [ -f "$RUNNER_DIR/.credentials" ]; then
  if [ -z "$EXPECTED_GH_NORM" ] || [ "$EXISTING_GH_NORM" = "$EXPECTED_GH_NORM" ]; then
    if [ -z "$RUNNER_NAME" ] || [ "$EXISTING_AGENT_NAME" = "$RUNNER_NAME" ]; then
      REUSE_EXISTING=true
    fi
  fi
fi

RUNNER_STARTED=false
if [ -x "$RUNNER_DIR/config.sh" ]; then
  if [ "$REUSE_EXISTING" = "true" ]; then
    echo "[bootstrap] Preserved runner credentials found ($EXISTING_AGENT_NAME); starting systemd service..."
    if [ -x "$RUNNER_DIR/svc.sh" ]; then
      if (
        cd "$RUNNER_DIR" || exit 1
        ./svc.sh stop >/dev/null 2>&1 || true
        ./svc.sh uninstall >/dev/null 2>&1 || true
        rm -f "$RUNNER_DIR/.service"
        chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
        ./svc.sh install "$RUNNER_USER" && ./svc.sh start
      ); then
        SVC_NAME="$(tr -d '\r\n' < "$RUNNER_DIR/.service" 2>/dev/null || true)"
        sleep 3
        if [ -n "$SVC_NAME" ] && systemctl is-active --quiet "$SVC_NAME"; then
          RUNNER_STARTED=true
        else
          echo "[warn] Preserved runner service did not stay active; will attempt fresh registration."
        fi
      else
        echo "[warn] Failed to start runner using preserved credentials; will attempt fresh registration."
      fi
    else
      echo "[bootstrap] svc.sh not present alongside restored credentials; generating fallback systemd unit..."
      RUN_CMD="$RUNNER_DIR/run.sh"
      if [ -f "$RUNNER_DIR/bin/runsvc.sh" ]; then
        cp "$RUNNER_DIR/bin/runsvc.sh" "$RUNNER_DIR/runsvc.sh"
        chmod 0755 "$RUNNER_DIR/runsvc.sh"
        RUN_CMD="$RUNNER_DIR/runsvc.sh"
      elif [ -x "$RUNNER_DIR/runsvc.sh" ]; then
        RUN_CMD="$RUNNER_DIR/runsvc.sh"
      fi
      chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
      FALLBACK_SVC="actions.runner.gpu.service"
      cat <<RUNSVCEOF > "/etc/systemd/system/$FALLBACK_SVC"
[Unit]
Description=GitHub Actions Runner ($EXISTING_AGENT_NAME)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$RUN_CMD
User=$RUNNER_USER
WorkingDirectory=$RUNNER_DIR
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
RUNSVCEOF
      systemctl daemon-reload
      systemctl enable --now "$FALLBACK_SVC" || true
      sleep 3
      if systemctl is-active --quiet "$FALLBACK_SVC"; then
        RUNNER_STARTED=true
      else
        echo "[warn] Fallback runner systemd service did not stay active; will attempt fresh registration."
      fi
    fi
  fi

  if [ "$RUNNER_STARTED" != "true" ] && [ -n "$GITHUB_REPO" ]; then
    EFFECTIVE_RUNNER_NAME="$${RUNNER_NAME:-${local.effective_runner_name}}"
    EFFECTIVE_RUNNER_LABELS="$${RUNNER_LABELS:-${var.runner_labels}}"
    REG_TOK=""
    if [ -n "$RUNNER_PAT" ]; then
      REG_TOK="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 30 -X POST \
        -H "Authorization: Bearer $RUNNER_PAT" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$GITHUB_REPO/actions/runners/registration-token" 2>/dev/null \
        | jq -r '.token // empty' 2>/dev/null || true)"
    fi
    if [ -z "$REG_TOK" ] && [ -n "$RUNNER_TOKEN" ]; then
      REG_TOK="$RUNNER_TOKEN"
    fi

    if [ -n "$REG_TOK" ]; then
      echo "[bootstrap] Registering GitHub Actions runner '$EFFECTIVE_RUNNER_NAME' against $GITHUB_REPO..."
      if (
        cd "$RUNNER_DIR" || exit 1
        systemctl disable --now actions.runner.gpu.service >/dev/null 2>&1 || true
        if [ -x ./svc.sh ]; then
          ./svc.sh stop >/dev/null 2>&1 || true
          ./svc.sh uninstall >/dev/null 2>&1 || true
        fi
        rm -f "$RUNNER_DIR/.service" "$RUNNER_DIR/.runner" "$RUNNER_DIR/.credentials" "$RUNNER_DIR/.credentials_rsaparams"
        chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
        timeout 300 sudo -H -u "$RUNNER_USER" "$RUNNER_DIR/config.sh" \
          --unattended \
          --url "https://github.com/$GITHUB_REPO" \
          --token "$REG_TOK" \
          --name "$EFFECTIVE_RUNNER_NAME" \
          --labels "$EFFECTIVE_RUNNER_LABELS" \
          --work _work \
          --replace && \
        ./svc.sh install "$RUNNER_USER" && \
        ./svc.sh start
      ); then
        RUNNER_STARTED=true
        if command -v gcloud >/dev/null 2>&1 && [ -n "$CACHE_BUCKET" ]; then
          echo "[bootstrap] Persisting fresh runner credentials to gs://$CACHE_BUCKET/actions-runner-state/..."
          for rf in .runner .credentials .credentials_rsaparams .env .path svc.sh runsvc.sh; do
            if [ -f "$RUNNER_DIR/$rf" ]; then
              timeout 60 gcloud storage cp "$RUNNER_DIR/$rf" "gs://$CACHE_BUCKET/actions-runner-state/$rf" >/dev/null 2>&1 || true
            fi
          done
        fi
      else
        echo "[warn] GitHub Actions runner registration failed."
      fi
    else
      echo "[warn] No registration token or PAT available for $GITHUB_REPO; skipping runner registration."
    fi
  fi
else
  echo "[warn] $RUNNER_DIR/config.sh not found; skipping runner setup."
fi
unset BOOTSTRAP_JSON RUNNER_TOKEN RUNNER_PAT REG_TOK

# 9. Boot hook, controlled by the runner: after every successful pipeline, deploy_gpu_stack.sh publishes
#    gs://$CACHE_BUCKET/boot-hook/hook.sh (restore the stack files that deploy saved to GCS and re-run it with --resume).
#    Failsafe: the hook is disarmed (moved to running.sh) BEFORE it runs and re-armed only when it exits 0. A failure, a
#    timeout or a VM lost mid-run leaves it disarmed (failed.sh / running.sh), so later boots skip it until the next
#    successful pipeline publishes it again. It runs detached (gpu-boot-hook.service), after the runner is up.
cat <<'HOOKEOF' > /usr/local/bin/gpu-boot-hook
#!/usr/bin/env bash
set -uo pipefail
export HOME=/root
export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
. /etc/gpu-cache-bucket
HOOK_URL="gs://$CACHE_BUCKET/boot-hook"
WORK=/mnt/data/boot-hook
mkdir -p "$WORK"
if ! timeout 300 gcloud storage cp "$HOOK_URL/running.sh" "$WORK/hook.sh" >/dev/null 2>&1; then
  echo "[boot-hook] Could not fetch the disarmed hook; it stays disarmed until the next pipeline."
  exit 1
fi
echo "[boot-hook] Running the hook published by the last successful pipeline (timeout $${GPU_BOOT_HOOK_TIMEOUT}s)..."
timeout "$${GPU_BOOT_HOOK_TIMEOUT}" bash "$WORK/hook.sh"
rc=$?
if [ "$rc" -eq 0 ]; then
  timeout 300 gcloud storage mv "$HOOK_URL/running.sh" "$HOOK_URL/hook.sh" >/dev/null 2>&1 \
    && echo "[boot-hook] Succeeded; re-armed for the next boot." \
    || echo "[boot-hook] Succeeded, but could not re-arm it (the next pipeline will)."
else
  timeout 300 gcloud storage mv "$HOOK_URL/running.sh" "$HOOK_URL/failed.sh" >/dev/null 2>&1 || true
  echo "[boot-hook] Failed (exit $rc); disarmed until the next successful pipeline."
fi
exit "$rc"
HOOKEOF
chmod 0755 /usr/local/bin/gpu-boot-hook
# Never fatal and never blocking: the runner is already up, so whatever happens here only affects the stack resume.
if timeout 120 gcloud storage mv "gs://$CACHE_BUCKET/boot-hook/hook.sh" "gs://$CACHE_BUCKET/boot-hook/running.sh" >/dev/null 2>&1; then
  if systemd-run --unit=gpu-boot-hook --collect --setenv=GPU_BOOT_HOOK_TIMEOUT=${local.boot_hook_timeout_sec} \
       /usr/local/bin/gpu-boot-hook >/dev/null 2>&1; then
    echo "[bootstrap] Boot hook disarmed and started (gpu-boot-hook.service); it re-arms itself only if it succeeds."
  else
    echo "[warn] Could not start gpu-boot-hook.service; the hook stays disarmed until the next pipeline."
  fi
else
  echo "[bootstrap] No armed boot hook (never published, or the last one failed): the stack waits for the pipeline."
fi

echo "=== [gpu-mig-bootstrap] Finished at $(date -Is) (runner_started=$RUNNER_STARTED) ==="
EOF

  gpu_shutdown_script = <<EOF
#!/usr/bin/env bash
set -u
export HOME="/root"
export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# A boot hook interrupted by a Spot preemption did not fail: re-arm it (running.sh -> hook.sh) so the next VM resumes the
# stack. First, because a preempted VM gets ~30 s. Every other shutdown (MIG delete / autohealing, stop, a hook that
# brought the VM down) leaves it disarmed, as the failsafe in the startup script intends.
if systemctl is-active --quiet gpu-boot-hook.service 2>/dev/null && [ -r /etc/gpu-cache-bucket ] && \
   [ "$(curl -s -m 2 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/preempted)" = "TRUE" ]; then
  . /etc/gpu-cache-bucket
  timeout 15 gcloud storage mv "gs://$CACHE_BUCKET/boot-hook/running.sh" "gs://$CACHE_BUCKET/boot-hook/hook.sh" >/dev/null 2>&1 \
    && echo "[shutdown] Preempted while the boot hook was running; re-armed it for the next VM."
fi
if command -v podman >/dev/null 2>&1; then
  podman stop -t 10 --all >/dev/null 2>&1 || true
fi
if [ -x /usr/local/bin/gpu-gcs-sync ]; then
  timeout 15 /usr/local/bin/gpu-gcs-sync --fast || true
fi
sync
if mountpoint -q /mnt/data; then
  umount -f /mnt/data || true
fi
EOF
}

# Same-region GCS cache bucket persisting Hugging Face weights, stack config, harness workspace, and runner state
# across Spot preemptions and cross-zone failovers ($0 same-region GCE <-> GCS transfer).
resource "google_storage_bucket" "gpu_cache" {
  project                     = var.project_id
  name                        = local.effective_cache_bucket_name
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.cache_bucket_force_destroy
  labels                      = var.labels
}

resource "google_storage_bucket_iam_member" "gpu_cache_admin" {
  bucket = google_storage_bucket.gpu_cache.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.gpu.email}"
}

# Secret Manager secret holding the GitHub Actions runner bootstrap JSON payload.
resource "google_secret_manager_secret" "runner_bootstrap" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-runner-bootstrap"
  labels    = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "gpu_runner_bootstrap" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.runner_bootstrap.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.gpu.email}"
}

resource "google_secret_manager_secret_version" "runner_bootstrap" {
  count = local.create_runner_secret_version ? 1 : 0

  secret = google_secret_manager_secret.runner_bootstrap.id
  secret_data = jsonencode({
    github_repo   = trimspace(var.github_repo)
    runner_name   = local.effective_runner_name
    runner_labels = var.runner_labels
    runner_token  = var.runner_token
    runner_pat    = var.runner_pat
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Instance template for the stateless multi-zone GPU Regional Managed Instance Group.
resource "google_compute_instance_template" "gpu" {
  project      = var.project_id
  name_prefix  = "${var.name_prefix}-tpl-"
  region       = var.region
  machine_type = var.machine_type
  tags         = ["${var.name_prefix}-vm"]
  labels       = var.labels

  disk {
    boot                   = true
    auto_delete            = true
    type                   = "PERSISTENT"
    mode                   = "READ_WRITE"
    source_image           = var.boot_image
    disk_type              = var.boot_disk_type
    disk_size_gb           = var.boot_disk_size_gb
    provisioned_iops       = startswith(var.boot_disk_type, "hyperdisk") ? var.boot_disk_iops : null
    provisioned_throughput = startswith(var.boot_disk_type, "hyperdisk") ? var.boot_disk_throughput_mbps : null
  }

  disk {
    boot         = false
    auto_delete  = true
    type         = "PERSISTENT"
    mode         = "READ_WRITE"
    device_name  = "data"
    disk_type    = var.data_disk_type
    disk_size_gb = var.data_disk_size_gb
    # Provisioned performance exists only for Hyperdisk (pd-* types, e.g. on G2 test VMs, reject it).
    provisioned_iops       = startswith(var.data_disk_type, "hyperdisk") ? var.data_disk_iops : null
    provisioned_throughput = startswith(var.data_disk_type, "hyperdisk") ? var.data_disk_throughput_mbps : null
    labels                 = var.labels
  }

  network_interface {
    subnetwork = local.subnetwork_id
    nic_type   = "GVNIC"

    dynamic "access_config" {
      for_each = var.enable_external_ip ? [1] : []
      content {
        network_tier = "PREMIUM"
      }
    }
  }

  scheduling {
    automatic_restart           = !var.use_spot
    on_host_maintenance         = "TERMINATE"
    preemptible                 = var.use_spot
    provisioning_model          = var.use_spot ? "SPOT" : "STANDARD"
    instance_termination_action = var.use_spot ? "STOP" : null
  }

  shielded_instance_config {
    enable_secure_boot          = var.enable_shielded_vm
    enable_vtpm                 = var.enable_shielded_vm
    enable_integrity_monitoring = var.enable_shielded_vm
  }

  service_account {
    email  = google_service_account.gpu.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    enable-oslogin         = var.enable_os_login ? "TRUE" : "FALSE"
    block-project-ssh-keys = "TRUE"
    startup-script         = local.gpu_startup_script
    shutdown-script        = local.gpu_shutdown_script
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Autohealing probe (gpu-health in the startup script, runner service only): a VM whose runner never starts (boot hang)
# or dies, or that stops answering, is recreated by the MIG (in whichever zone has capacity) after 5 failed checks (~5 min).
resource "google_compute_health_check" "gpu" {
  count = local.autohealing_enabled ? 1 : 0

  project             = var.project_id
  name                = "${var.name_prefix}-health"
  description         = "gpu-health host probe of the GPU MIG VM (GitHub Actions runner service)"
  check_interval_sec  = 60
  timeout_sec         = 10
  healthy_threshold   = 1
  unhealthy_threshold = 5

  http_health_check {
    port         = var.health_check_port
    request_path = "/health"
  }
}

# Single-VM Stateless Multi-Zone Regional Managed Instance Group allowing automatic cross-zone Spot failover;
# persistent model weights, stack config, harness workspace, and runner credentials live in google_storage_bucket.gpu_cache.
resource "google_compute_region_instance_group_manager" "gpu" {
  project                          = var.project_id
  name                             = "${var.name_prefix}-mig"
  base_instance_name               = "${var.name_prefix}-vm"
  region                           = var.region
  target_size                      = 1
  wait_for_instances               = false
  distribution_policy_zones        = length(local.effective_zones) > 0 ? local.effective_zones : null
  distribution_policy_target_shape = "ANY"

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.gpu.self_link_unique
  }

  dynamic "auto_healing_policies" {
    for_each = local.autohealing_enabled ? [1] : []
    content {
      health_check      = google_compute_health_check.gpu[0].id
      initial_delay_sec = var.autohealing_initial_delay_sec
    }
  }

  instance_lifecycle_policy {
    default_action_on_failure = "REPAIR"
    force_update_on_repair    = "YES"
    on_repair {
      allow_changing_zone = "YES"
    }
  }

  update_policy {
    type                           = "PROACTIVE"
    instance_redistribution_type   = "NONE"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    replacement_method             = "SUBSTITUTE"
    max_surge_fixed                = 0
    max_unavailable_fixed          = max(length(local.effective_zones), 3)
  }

  depends_on = [
    google_compute_firewall.allow_health_checks,
    google_compute_router_nat.nat,
    google_secret_manager_secret_iam_member.gpu_runner_bootstrap,
    google_secret_manager_secret_version.runner_bootstrap,
    google_storage_bucket_iam_member.gpu_cache_admin,
  ]
}
