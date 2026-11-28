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
  create_runner_secret_version = (
    trimspace(var.github_repo) != "" &&
    (trimspace(var.runner_token) != "" || trimspace(var.runner_pat) != "")
  )

  gpu_startup_script = <<EOF
#!/usr/bin/env bash
set -euo pipefail

mkdir -p /var/log
exec > >(tee -a /var/log/gpu-mig-bootstrap.log) 2>&1
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
  echo "[error] Ephemeral data disk $DATA_DISK not found; aborting bootstrap to avoid filling boot disk." >&2
  exit 1
fi

mkdir -p "$MOUNT_POINT"
if ! blkid "$DATA_DISK" >/dev/null 2>&1; then
  echo "[bootstrap] Formatting $DATA_DISK as ext4..."
  mkfs.ext4 -F -m 0 -E lazy_itable_init=1,lazy_journal_init=1,nodiscard "$DATA_DISK"
fi
if ! mountpoint -q "$MOUNT_POINT"; then
  mount -o discard,defaults "$DATA_DISK" "$MOUNT_POINT"
fi
UUID="$(blkid -s UUID -o value "$DATA_DISK")"
if [ -n "$UUID" ] && ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID $MOUNT_POINT ext4 discard,defaults,nofail 0 2" >> /etc/fstab
fi
chmod 1777 "$MOUNT_POINT"
# Large readahead: vLLM loads the safetensors checkpoint through mmap page faults, which with the default 128 KiB
# readahead become ~20 KiB reads and pin the disk at its IOPS cap (76 MB/s on a 4,000-IOPS replica). 16 MiB gave
# ~92 KiB reads and 4.7x faster loading. Same setting as development/scripts/deploy_gpu_stack.sh.
DATA_BLK="$(lsblk -ndo PKNAME "$DATA_DISK" 2>/dev/null)"
[ -n "$DATA_BLK" ] || DATA_BLK="$(basename "$(readlink -f "$DATA_DISK")")"
echo 16384 > "/sys/block/$DATA_BLK/queue/read_ahead_kb" 2>/dev/null || echo "[warn] Could not set readahead on $DATA_BLK."

# 2. Create working directories on /mnt/data (persistent state is synced to the regional GCS cache bucket).
mkdir -p \
  /mnt/data/containers/storage \
  /mnt/data/containers/tmp \
  /mnt/data/huggingface \
  /mnt/data/vllm-cache \
  /mnt/data/deepseek-harness/dsh-home \
  /mnt/data/deepseek-harness/workspace \
  /mnt/data/reverse-tunnel/state/litellm \
  /mnt/data/reverse-tunnel/state/harness \
  /mnt/data/stacks/gpu-dev-machine \
  /mnt/data/actions-runner

chmod 0700 /mnt/data/reverse-tunnel
chmod 1777 \
  /mnt/data/deepseek-harness \
  /mnt/data/deepseek-harness/dsh-home \
  /mnt/data/deepseek-harness/workspace \
  /mnt/data/reverse-tunnel/state \
  /mnt/data/reverse-tunnel/state/litellm \
  /mnt/data/reverse-tunnel/state/harness
touch /mnt/data/reverse-tunnel/known_hosts
chmod 0644 /mnt/data/reverse-tunnel/known_hosts

# 3. Point Podman storage at /mnt/data so large container layers never fill the boot disk.
mkdir -p /etc/containers
cat <<'STORAGEEOF' > /etc/containers/storage.conf
[storage]
driver = "overlay"
graphroot = "/mnt/data/containers/storage"
runroot = "/run/containers/storage"
STORAGEEOF

# 4. Provision local runner user with passwordless sudo and symlink /opt/actions-runner -> /mnt/data/actions-runner.
RUNNER_USER="${var.runner_username}"
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$RUNNER_USER"
fi
usermod -aG sudo "$RUNNER_USER" || true
echo "$RUNNER_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$RUNNER_USER"
chmod 0440 "/etc/sudoers.d/90-$RUNNER_USER"
chown -R "$RUNNER_USER:$RUNNER_USER" /mnt/data/actions-runner /mnt/data/stacks
if [ -d /opt/actions-runner ] && [ ! -L /opt/actions-runner ]; then
  rm -rf /opt/actions-runner
fi
ln -sfn /mnt/data/actions-runner /opt/actions-runner

# 5. Install required OS, GitHub runner, and Podman packages.
HOST_PACKAGES=(
  ca-certificates
  curl
  fuse-overlayfs
  git
  git-lfs
  gpg
  jq
  libicu-dev
  libkrb5-3
  libssl-dev
  podman
  podman-compose
  netavark
  aardvark-dns
  rsync
  slirp4netns
  tar
  uidmap
  unzip
  xz-utils
  zip
  zlib1g
)
if ! dpkg -s "$${HOST_PACKAGES[@]}" >/dev/null 2>&1; then
  echo "[bootstrap] Installing OS, runner, and Podman packages..."
  for _ in 1 2 3; do
    if apt-get -o DPkg::Lock::Timeout=180 update -qq && \
       apt-get -o DPkg::Lock::Timeout=180 install -y -qq --no-install-recommends "$${HOST_PACKAGES[@]}"; then
      break
    fi
    sleep 5
  done
fi
git lfs install --system >/dev/null 2>&1 || true

# 6. Install Canonical Secure-Boot-signed NVIDIA Open Kernel GPU driver + NVIDIA Container Toolkit + Podman CDI.
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

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  echo "[bootstrap] Installing NVIDIA Container Toolkit for Podman CDI..."
  if curl -fsSL --retry 3 --retry-delay 2 https://nvidia.github.io/libnvidia-container/gpgkey \
       | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && \
     curl -fsSL --retry 3 --retry-delay 2 https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
       | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
       > /etc/apt/sources.list.d/nvidia-container-toolkit.list && \
     apt-get -o DPkg::Lock::Timeout=180 update -qq && \
     apt-get -o DPkg::Lock::Timeout=180 install -y -qq nvidia-container-toolkit; then
    echo "[bootstrap] Installed nvidia-container-toolkit."
  else
    echo "[warn] Failed to install nvidia-container-toolkit; continuing bootstrap."
  fi
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

if command -v nvidia-ctk >/dev/null 2>&1; then
  mkdir -p /etc/cdi
  # Podman < 5 (Ubuntu 24.04 ships 4.9.3) bundles CDI library v0.6.x, which only accepts specs up to
  # cdiVersion 0.6.0 and silently skips newer ones ("unresolvable CDI devices nvidia.com/gpu=all"). nvidia-ctk
  # emits 0.7.0 only for the v0.7.0 fields additionalGids/intelRdt (render-node groups, not needed by CUDA),
  # so drop those and declare 0.6.0. Same conversion as development/scripts/deploy_gpu_stack.sh.
  PODMAN_MAJOR="$(podman --version 2>/dev/null | grep -oE '[0-9]+' | head -n1)"
  python3 - /etc/cdi/nvidia.yaml "$${PODMAN_MAJOR:-4}" <<'PY' || echo "[warn] Failed to write /etc/cdi/nvidia.yaml."
import json, os, subprocess, sys
dst, podman_major = sys.argv[1], int(sys.argv[2] or 4)
out = subprocess.run(["nvidia-ctk", "cdi", "generate", "--format=json"], check=True, capture_output=True, text=True).stdout
spec = json.loads(out)
if podman_major < 5:
    for edits in [spec.get("containerEdits") or {}] + [d.get("containerEdits") or {} for d in spec.get("devices", [])]:
        edits.pop("additionalGids", None)
        edits.pop("intelRdt", None)
    spec["cdiVersion"] = "0.6.0"
with open(dst + ".tmp", "w") as fh:
    json.dump(spec, fh, indent=2)
os.replace(dst + ".tmp", dst)
print("[bootstrap] CDI spec " + dst + ": cdiVersion " + spec["cdiVersion"] + ", devices: " + ",".join(d.get("name", "?") for d in spec.get("devices", [])))
PY
fi

# 7. Configure regional GCS cache bucket metadata, sync helper (/usr/local/bin/gpu-gcs-sync), and systemd timer.
CACHE_BUCKET="${google_storage_bucket.gpu_cache.name}"
cat <<'CACHEEOF' > /etc/gpu-cache-bucket
CACHE_BUCKET="${google_storage_bucket.gpu_cache.name}"
CACHEEOF
chmod 0644 /etc/gpu-cache-bucket

cat <<'SYNCEOF' > /usr/local/bin/gpu-gcs-sync
#!/usr/bin/env bash
set -uo pipefail

export HOME="/root"
export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

FAST_MODE=false
for arg in "$@"; do
  case "$arg" in
    --fast) FAST_MODE=true ;;
  esac
done

if [ -f /etc/gpu-cache-bucket ]; then
  # shellcheck disable=SC1091
  . /etc/gpu-cache-bucket
fi

if [ -z "$${CACHE_BUCKET:-}" ]; then
  echo "[gpu-gcs-sync] CACHE_BUCKET is not configured; skipping."
  exit 0
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "[gpu-gcs-sync] gcloud not found; skipping."
  exit 0
fi

if ! mountpoint -q /mnt/data; then
  echo "[gpu-gcs-sync] /mnt/data is not mounted; skipping."
  exit 0
fi

# Phase 1 (--fast and full): sync small stack configs, reverse-tunnel keys, harness state, and runner credentials.
(
  flock -n 9 || {
    echo "[gpu-gcs-sync] Small-state sync already running; skipping."
    exit 0
  }

  if [ -d /mnt/data/stacks/gpu-dev-machine ] && [ -n "$(ls -A /mnt/data/stacks/gpu-dev-machine 2>/dev/null)" ]; then
    gcloud storage rsync -r -c /mnt/data/stacks/gpu-dev-machine "gs://$${CACHE_BUCKET}/stacks/gpu-dev-machine" || true
  fi

  if [ -d /mnt/data/reverse-tunnel ] && [ -n "$(ls -A /mnt/data/reverse-tunnel 2>/dev/null)" ]; then
    gcloud storage rsync -r -c /mnt/data/reverse-tunnel "gs://$${CACHE_BUCKET}/reverse-tunnel" || true
  fi

  if [ -d /mnt/data/deepseek-harness ] && [ -n "$(ls -A /mnt/data/deepseek-harness 2>/dev/null)" ]; then
    gcloud storage rsync -r -c /mnt/data/deepseek-harness "gs://$${CACHE_BUCKET}/deepseek-harness" || true
  fi

  for rf in .runner .credentials .credentials_rsaparams .env .path svc.sh runsvc.sh; do
    if [ -f "/mnt/data/actions-runner/$rf" ]; then
      gcloud storage cp "/mnt/data/actions-runner/$rf" "gs://$${CACHE_BUCKET}/actions-runner-state/$rf" || true
    fi
  done
) 9>/run/gpu-gcs-sync.lock

if [ "$FAST_MODE" = "true" ]; then
  exit 0
fi

# Phase 2 (full sync): sync Hugging Face model cache (blobs + symlink manifest, skipping .locks and .incomplete files).
(
  flock -n 8 || {
    echo "[gpu-gcs-sync] Hugging Face sync already running; skipping."
    exit 0
  }

  if [ -d /mnt/data/huggingface ] && [ -n "$(ls -A /mnt/data/huggingface 2>/dev/null)" ]; then
    python3 - /mnt/data/huggingface <<'PY' || true
import os, sys
root = sys.argv[1]
entries = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d != ".locks"]
    for name in filenames + dirnames:
        full = os.path.join(dirpath, name)
        if os.path.islink(full):
            rel = os.path.relpath(full, root)
            entries.append((rel, os.readlink(full)))
if entries:
    entries.sort()
    tmp = os.path.join(root, ".gcs-symlinks.tsv.tmp")
    dst = os.path.join(root, ".gcs-symlinks.tsv")
    with open(tmp, "w", encoding="utf-8") as fh:
        for rel, target in entries:
            fh.write(f"{rel}\t{target}\n")
    os.replace(tmp, dst)
PY
    # No -c here: checksum mode hashes every local file on every run, i.e. re-reads the ~475 GiB checkpoint (~11 min
    # of saturated disk every 15 min). HF blobs are content-addressed and immutable, so size + mtime (stored by
    # gcloud in object metadata) is enough and later runs are just listings.
    gcloud storage rsync -r \
      --exclude='(^|.*/)\.locks/.*|.*\.incomplete$|.*\.gcs-symlinks\.tsv\.tmp$' \
      /mnt/data/huggingface "gs://$${CACHE_BUCKET}/huggingface" || true
  fi

  # Compile/JIT caches (vLLM torch.compile, FlashInfer, TileLang, Triton, CuTe-DSL): restoring them saves ~10 min of
  # kernel compilation/autotuning on every Spot recreation.
  if [ -d /mnt/data/vllm-cache ] && [ -n "$(ls -A /mnt/data/vllm-cache 2>/dev/null)" ]; then
    gcloud storage rsync -r /mnt/data/vllm-cache "gs://$${CACHE_BUCKET}/vllm-cache" || true
  fi
) 8>/run/gpu-gcs-sync-hf.lock
SYNCEOF
chmod 0755 /usr/local/bin/gpu-gcs-sync

cat <<'SVCEOF' > /etc/systemd/system/gpu-gcs-sync.service
[Unit]
Description=Sync GPU VM state and Hugging Face cache to regional GCS cache bucket
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gpu-gcs-sync
SVCEOF

cat <<'TMREOF' > /etc/systemd/system/gpu-gcs-sync.timer
[Unit]
Description=Periodically sync GPU VM state and Hugging Face cache to GCS (every 15 minutes)

[Timer]
OnBootSec=15min
OnUnitActiveSec=15min
RandomizedDelaySec=60
Persistent=false

[Install]
WantedBy=timers.target
TMREOF

# 8. Unpack latest GitHub Actions runner binary into /mnt/data/actions-runner if not already present.
RUNNER_DIR="/mnt/data/actions-runner"
if [ ! -x "$RUNNER_DIR/config.sh" ]; then
  echo "[bootstrap] Downloading latest actions-runner-linux-x64 into $RUNNER_DIR..."
  RUNNER_LATEST_URL="$(curl -fsSLI --retry 3 --retry-delay 2 -o /dev/null -w '%%{url_effective}' https://github.com/actions/runner/releases/latest || true)"
  RUNNER_VER="$${RUNNER_LATEST_URL##*/v}"
  if [[ -n "$RUNNER_VER" && "$RUNNER_VER" != "$RUNNER_LATEST_URL" ]]; then
    TMP_TAR="$(mktemp /tmp/actions-runner.XXXXXX.tar.gz)"
    if curl -fsSL --retry 3 --retry-delay 2 "https://github.com/actions/runner/releases/download/v$${RUNNER_VER}/actions-runner-linux-x64-$${RUNNER_VER}.tar.gz" -o "$TMP_TAR"; then
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

# 9. Restore persisted runner state from GCS (if present), then start or self-register the GitHub Actions runner.
if command -v gcloud >/dev/null 2>&1 && [ -n "$CACHE_BUCKET" ]; then
  echo "[bootstrap] Checking gs://$CACHE_BUCKET/actions-runner-state/ for preserved runner credentials..."
  for rf in .runner .credentials .credentials_rsaparams .env .path svc.sh runsvc.sh; do
    if [ ! -f "$RUNNER_DIR/$rf" ]; then
      if gcloud storage cp "gs://$CACHE_BUCKET/actions-runner-state/$rf" "$RUNNER_DIR/$rf" >/dev/null 2>&1; then
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
    BOOTSTRAP_JSON="$(gcloud secrets versions access latest \
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
    ACCESS_TOKEN="$(curl -fsSL -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" 2>/dev/null \
      | jq -r '.access_token // empty' 2>/dev/null || true)"
    if [ -z "$ACCESS_TOKEN" ] && [ -f /run/google-mds-mtls/root.crt ] && [ -f /run/google-mds-mtls/client.key ]; then
      CERT_ARG="/run/google-mds-mtls/client.key"
      [ -f /run/google-mds-mtls/client.crt ] && CERT_ARG="/run/google-mds-mtls/client.crt"
      ACCESS_TOKEN="$(curl -fsSL \
        --cacert /run/google-mds-mtls/root.crt \
        --cert "$CERT_ARG" \
        --key /run/google-mds-mtls/client.key \
        -H "Metadata-Flavor: Google" \
        "https://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token" 2>/dev/null \
        | jq -r '.access_token // empty' 2>/dev/null || true)"
    fi
    if [ -n "$ACCESS_TOKEN" ]; then
      SM_HTTP_FILE="$(mktemp /tmp/sm-http.XXXXXX)"
      SM_CODE="$(curl -sSL -o "$SM_HTTP_FILE" -w '%%{http_code}' \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/$SECRET_ID/versions/latest:access" 2>/dev/null || true)"
      if [ "$SM_CODE" != "200" ] && [ -f /run/google-mds-mtls/client.key ]; then
        CERT_ARG="/run/google-mds-mtls/client.key"
        [ -f /run/google-mds-mtls/client.crt ] && CERT_ARG="/run/google-mds-mtls/client.crt"
        SM_CODE="$(curl -sSL -o "$SM_HTTP_FILE" -w '%%{http_code}' \
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
      REG_TOK="$(curl -fsSL --retry 3 --retry-delay 2 -X POST \
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
        sudo -H -u "$RUNNER_USER" "$RUNNER_DIR/config.sh" \
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
              gcloud storage cp "$RUNNER_DIR/$rf" "gs://$CACHE_BUCKET/actions-runner-state/$rf" >/dev/null 2>&1 || true
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

# 10. Restore persisted stack configs, tunnel keys, harness workspace, and Hugging Face weights from regional GCS cache.
STACK_DIR="/mnt/data/stacks/gpu-dev-machine"
if command -v gcloud >/dev/null 2>&1 && [ -n "$CACHE_BUCKET" ]; then
  echo "[bootstrap] Restoring stack config and runtime state from gs://$CACHE_BUCKET/..."
  gcloud storage rsync -r -c "gs://$CACHE_BUCKET/stacks/gpu-dev-machine" "$STACK_DIR" || true
  if [ -f "$STACK_DIR/.env" ]; then
    chmod 0600 "$STACK_DIR/.env"
  fi
  chown -R "$RUNNER_USER:$RUNNER_USER" /mnt/data/stacks

  gcloud storage rsync -r -c "gs://$CACHE_BUCKET/reverse-tunnel" /mnt/data/reverse-tunnel || true
  chmod 0700 /mnt/data/reverse-tunnel
  chmod 1777 \
    /mnt/data/reverse-tunnel/state \
    /mnt/data/reverse-tunnel/state/litellm \
    /mnt/data/reverse-tunnel/state/harness
  [ -f /mnt/data/reverse-tunnel/id_ed25519 ] && chmod 0644 /mnt/data/reverse-tunnel/id_ed25519
  [ -f /mnt/data/reverse-tunnel/known_hosts ] && chmod 0644 /mnt/data/reverse-tunnel/known_hosts

  gcloud storage rsync -r -c "gs://$CACHE_BUCKET/deepseek-harness" /mnt/data/deepseek-harness || true
  mkdir -p /mnt/data/deepseek-harness/dsh-home /mnt/data/deepseek-harness/workspace
  chown -R 1000:1000 /mnt/data/deepseek-harness/dsh-home /mnt/data/deepseek-harness/workspace || true
  chmod 1777 \
    /mnt/data/deepseek-harness \
    /mnt/data/deepseek-harness/dsh-home \
    /mnt/data/deepseek-harness/workspace
  find /mnt/data/deepseek-harness/dsh-home -type f -perm /1077 -exec chmod go-rwx,-t {} + 2>/dev/null || true
  [ -f /mnt/data/deepseek-harness/dsh-home/.credentials.yaml ] && chmod 0600 /mnt/data/deepseek-harness/dsh-home/.credentials.yaml

  echo "[bootstrap] Restoring Hugging Face model cache from gs://$CACHE_BUCKET/huggingface/..."
  (
    flock -n 8 || true
    gcloud storage rsync -r "gs://$CACHE_BUCKET/huggingface" /mnt/data/huggingface || true
    python3 - /mnt/data/huggingface <<'PY' || true
import os, sys
root = sys.argv[1]
manifest = os.path.join(root, ".gcs-symlinks.tsv")
if os.path.isfile(manifest):
    restored = 0
    norm_root = os.path.normpath(root)
    with open(manifest, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if "\t" not in line:
                continue
            rel, target = line.split("\t", 1)
            link_path = os.path.normpath(os.path.join(norm_root, rel))
            if not link_path.startswith(norm_root + os.sep):
                continue
            resolved = os.path.normpath(os.path.join(os.path.dirname(link_path), target))
            if not os.path.exists(resolved):
                continue
            os.makedirs(os.path.dirname(link_path), exist_ok=True)
            if os.path.islink(link_path) or os.path.exists(link_path):
                if os.path.islink(link_path) and os.readlink(link_path) == target:
                    continue
                if os.path.isdir(link_path) and not os.path.islink(link_path):
                    continue
                os.unlink(link_path)
            os.symlink(target, link_path)
            restored += 1
    print(f"[bootstrap] Restored {restored} Hugging Face cache symlinks from manifest.")
PY
  ) 8>/run/gpu-gcs-sync-hf.lock

  echo "[bootstrap] Restoring compile/JIT caches from gs://$CACHE_BUCKET/vllm-cache/ (absent on first boot)..."
  mkdir -p /mnt/data/vllm-cache
  gcloud storage rsync -r "gs://$CACHE_BUCKET/vllm-cache" /mnt/data/vllm-cache >/dev/null 2>&1 || true
fi

# Enable and start the periodic 15-minute GCS sync timer after initial restore completes.
systemctl daemon-reload || true
systemctl enable --now gpu-gcs-sync.timer || echo "[warn] Failed to enable/start gpu-gcs-sync.timer."

# 11. Auto-resume previously deployed Podman stack after Spot recreation or cross-zone failover.
if [ -f "$STACK_DIR/compose.yml" ] && [ -f "$STACK_DIR/.env" ]; then
  echo "[bootstrap] Detected previously deployed Podman stack in $STACK_DIR; resuming..."
  # Container DNS needs netavark + aardvark-dns (Podman 4.9's CNI fallback has no DNS plugin); same setting as
  # development/scripts/deploy_gpu_stack.sh. Written before any podman command so it applies to this boot.
  mkdir -p /etc/containers/containers.conf.d
  printf '# Managed by personal-infra (development/infra/gcp/main.tf)\n[network]\nnetwork_backend = "netavark"\n' \
    > /etc/containers/containers.conf.d/50-personal-infra-netavark.conf
  # Default 2048-task limit per container is too low for vLLM's 4 TP workers on 192 vCPUs (EAGAIN after loading).
  printf '# Managed by personal-infra (development/infra/gcp/main.tf)\n[containers]\npids_limit = 65536\n' \
    > /etc/containers/containers.conf.d/51-personal-infra-pids.conf
  podman system migrate >/dev/null 2>&1 || true
  TUNNEL_HOST_SET="$(grep -E '^(TUNNEL_SSH_HOST|LITELLM_TUNNEL_SSH_HOST|HARNESS_TUNNEL_SSH_HOST)=' "$STACK_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]"'\''' || true)"
  if [ -n "$TUNNEL_HOST_SET" ] && [ -s /mnt/data/reverse-tunnel/id_ed25519 ]; then
    (cd "$STACK_DIR" && TMPDIR=/mnt/data/containers/tmp podman-compose -f compose.yml up -d --build) || \
      echo "[warn] Failed to auto-resume full podman-compose stack."
  else
    (cd "$STACK_DIR" && TMPDIR=/mnt/data/containers/tmp podman-compose -f compose.yml up -d --build vllm-server litellm deepseek-harness) || \
      echo "[warn] Failed to auto-resume core podman-compose stack."
  fi
fi

echo "=== [gpu-mig-bootstrap] Finished at $(date -Is) (runner_started=$RUNNER_STARTED) ==="
EOF

  gpu_shutdown_script = <<EOF
#!/usr/bin/env bash
set -u
export HOME="/root"
export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
    provisioned_iops       = var.boot_disk_iops
    provisioned_throughput = var.boot_disk_throughput_mbps
  }

  disk {
    boot                   = false
    auto_delete            = true
    type                   = "PERSISTENT"
    mode                   = "READ_WRITE"
    device_name            = "data"
    disk_type              = var.data_disk_type
    disk_size_gb           = var.data_disk_size_gb
    provisioned_iops       = var.data_disk_iops
    provisioned_throughput = var.data_disk_throughput_mbps
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
