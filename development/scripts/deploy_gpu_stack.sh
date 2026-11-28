#!/usr/bin/env bash
# Deploys the `development/gpu-dev-machine` Podman + `podman-compose` stack onto
# the target GPU machine from a self-hosted GitHub Actions runner (or locally).
#
# Supports three target modes (`--target-mode` / `GPU_TARGET_MODE`):
#   * `local`:          deploys directly on the current GPU host (default on GCP Regional MIG runner).
#   * `ssh`:            syncs and deploys over standard SSH to `GPU_SSH_HOST`.
#   * `controller-ssh`: syncs and deploys over `/usr/local/bin/gpu-ssh` (`gpu` host alias) if present.
#   * `auto` (default): picks `controller-ssh` if `/usr/local/bin/gpu-ssh` exists,
#                       else `ssh` if `GPU_SSH_HOST` is set, else `local`.
#
# Secret hygiene: secret values are streamed over stdin with mode 0600 and never
# printed to stdout/stderr (preflight logs only variable names).
#
# Everything the stack needs on the GPU host is done here, by the runner (the VM startup script only brings the
# machine and the runner up): Podman + NVIDIA CDI setup, restoring the GCS cache onto a fresh disk, the gpu-gcs-sync
# timer, the containers (incl. log-shipper), and finally publishing the boot hook. The hook re-runs this script with
# --resume on the next VM boot, from the copy saved in the GCS cache; it is disarmed if it fails, until the next
# successful pipeline publishes it again.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STACK_SRC_DIR="$DEV_ROOT/gpu-dev-machine"

TARGET_MODE="${GPU_TARGET_MODE:-auto}"
SSH_HOST="${GPU_SSH_HOST:-}"
REMOTE_STACK_DIR="${GPU_REMOTE_STACK_DIR:-/mnt/data/stacks/gpu-dev-machine}"
DATA_ROOT="${GPU_DATA_ROOT:-/mnt/data}"
WAIT_TIMEOUT_SEC="${GPU_WAIT_TIMEOUT_SEC:-600}"
WAIT_FOR_MODEL="${WAIT_FOR_MODEL:-true}"
MODEL_READY_TIMEOUT_SEC="${MODEL_READY_TIMEOUT_SEC:-10800}"
DRY_RUN=false
RESUME=false

usage() {
  cat <<'EOF'
Usage: ./development/scripts/deploy_gpu_stack.sh [options]

Deploys `development/gpu-dev-machine` (vLLM DeepSeek-V4.1-Flash, LiteLLM,
DeepSeek Harness, and optional reverse SSH tunnels) via Podman + podman-compose.

Options:
  --target-mode=MODE      Execution mode: auto, local, ssh, or controller-ssh (default: auto -> local on GPU runner)
  --ssh-host=USER@HOST    Target SSH host when --target-mode=ssh (or env GPU_SSH_HOST)
  --stack-dir=PATH        Destination stack directory on GPU host (default: /mnt/data/stacks/gpu-dev-machine)
  --wait-timeout=SECONDS  Max seconds to wait for GPU SSH in controller-ssh mode (default: 600)
  --no-wait-for-model     Finish once the containers run instead of waiting for vLLM to serve (env WAIT_FOR_MODEL=false)
  --model-timeout=SECONDS Max seconds to wait for vllm-server /health + a LiteLLM chat check (default: 10800;
                          a first start downloads ~475 GiB and loads it, which takes well over an hour)
  --resume                Boot-hook mode (run on the GPU host by the VM startup script): redeploy the stack files and
                          .env the last successful deploy saved to the GCS cache (already restored into --stack-dir),
                          without GitHub secrets; never publishes the hook (the startup re-arms it on success)
  --dry-run               Print resolved target, synced env key names (never values), and commands without executing
  -h, --help              Show this help message and exit

Environment Secrets / Variables (supplied by `.github/workflows/deploy-gpu-machine.yml`):
  LITELLM_MASTER_KEY      Required Bearer token securing LiteLLM (:4000) and DeepSeek Harness
  HF_TOKEN                Optional Hugging Face read token for model weight downloads
  HARNESS_PASSWORD        Password for the harness /login page (basic auth, user HARNESS_USER, default admin)
  ENABLE_REVERSE_TUNNELS  Set true to start litellm-tunnel and deepseek-harness-tunnel (default: false)
  TUNNEL_SSH_HOST/USER    Destination host & user when reverse SSH tunnels are enabled
  TUNNEL_SSH_PRIVATE_KEY  OpenSSH private key content for reverse SSH tunnels

Examples:
  LITELLM_MASTER_KEY=sk-test ./development/scripts/deploy_gpu_stack.sh --dry-run
  ./development/scripts/deploy_gpu_stack.sh --target-mode=local
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-mode=*) TARGET_MODE="${1#*=}"; shift ;;
    --target-mode) TARGET_MODE="$2"; shift 2 ;;
    --ssh-host=*) SSH_HOST="${1#*=}"; shift ;;
    --ssh-host) SSH_HOST="$2"; shift 2 ;;
    --stack-dir=*) REMOTE_STACK_DIR="${1#*=}"; shift ;;
    --stack-dir) REMOTE_STACK_DIR="$2"; shift 2 ;;
    --wait-timeout=*) WAIT_TIMEOUT_SEC="${1#*=}"; shift ;;
    --wait-timeout) WAIT_TIMEOUT_SEC="$2"; shift 2 ;;
    --no-wait-for-model) WAIT_FOR_MODEL=false; shift ;;
    --model-timeout=*) MODEL_READY_TIMEOUT_SEC="${1#*=}"; shift ;;
    --model-timeout) MODEL_READY_TIMEOUT_SEC="$2"; shift 2 ;;
    --resume) RESUME=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[error] Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Boot-hook resume: the stack dir (compose files + .env + this script under .deploy/) was restored from the GCS cache
# by the hook; deploy it in place with the settings the last successful pipeline wrote into .env.
if $RESUME; then
  TARGET_MODE="local"
  STACK_SRC_DIR="$REMOTE_STACK_DIR"
  if [[ ! -f "$REMOTE_STACK_DIR/.env" ]]; then
    echo "[error] --resume needs $REMOTE_STACK_DIR/.env (restored from the GCS cache by the boot hook)." >&2
    exit 1
  fi
  if [[ -n "$(sed -n 's/^TUNNEL_SSH_HOST=//p' "$REMOTE_STACK_DIR/.env" | head -n1)" ]]; then
    ENABLE_REVERSE_TUNNELS=true
  else
    ENABLE_REVERSE_TUNNELS=false
  fi
  # The hook has its own 3 h timeout; a resumed start has no download, only the GCS restore and the load.
  MODEL_READY_TIMEOUT_SEC="${GPU_RESUME_MODEL_TIMEOUT_SEC:-5400}"
fi

if [[ ! -f "$STACK_SRC_DIR/compose.yml" ]]; then
  echo "[error] Stack compose.yml not found at $STACK_SRC_DIR/compose.yml" >&2
  exit 1
fi

if [[ "$TARGET_MODE" == "auto" ]]; then
  if [[ -x /usr/local/bin/gpu-ssh ]]; then
    TARGET_MODE="controller-ssh"
  elif [[ -n "$SSH_HOST" ]]; then
    TARGET_MODE="ssh"
  else
    TARGET_MODE="local"
  fi
fi

case "$TARGET_MODE" in
  controller-ssh) SSH_HOST="gpu" ;;
  ssh)
    if [[ -z "$SSH_HOST" ]]; then
      echo "[error] --ssh-host (or GPU_SSH_HOST) is required when --target-mode=ssh" >&2
      exit 1
    fi
    ;;
  local) ;;
  *)
    echo "[error] Unsupported --target-mode '$TARGET_MODE' (expected: auto, controller-ssh, ssh, local)" >&2
    exit 1
    ;;
esac

# Determine whether reverse SSH tunnel containers should be started.
ENABLE_TUNNELS_RAW="${ENABLE_REVERSE_TUNNELS:-}"
if [[ -z "$ENABLE_TUNNELS_RAW" ]]; then
  if [[ -n "${TUNNEL_SSH_HOST:-}" ]]; then
    ENABLE_TUNNELS="true"
  else
    ENABLE_TUNNELS="false"
  fi
else
  case "${ENABLE_TUNNELS_RAW,,}" in
    1|true|yes|on) ENABLE_TUNNELS="true" ;;
    *) ENABLE_TUNNELS="false" ;;
  esac
fi

if ! $DRY_RUN && ! $RESUME; then
  if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
    echo "[error] LITELLM_MASTER_KEY environment secret is required." >&2
    exit 1
  fi
  if [[ "$ENABLE_TUNNELS" == "true" ]]; then
    if [[ -z "${TUNNEL_SSH_HOST:-}" || -z "${TUNNEL_SSH_USER:-}" || -z "${TUNNEL_SSH_PRIVATE_KEY:-}" ]]; then
      echo "[error] Reverse tunnels enabled, but one or more required settings are missing: TUNNEL_SSH_HOST, TUNNEL_SSH_USER, TUNNEL_SSH_PRIVATE_KEY" >&2
      exit 1
    fi
  fi
fi

ENV_KEYS_PRESENT=()
for key in \
  LITELLM_MASTER_KEY HF_TOKEN HARNESS_USER HARNESS_PASSWORD \
  TUNNEL_SSH_HOST TUNNEL_SSH_PORT TUNNEL_SSH_USER TUNNEL_BIND_ADDRESS \
  REMOTE_LITELLM_PORT REMOTE_HARNESS_PORT \
  LITELLM_TUNNEL_SSH_HOST LITELLM_TUNNEL_SSH_PORT LITELLM_TUNNEL_SSH_USER \
  HARNESS_TUNNEL_SSH_HOST HARNESS_TUNNEL_SSH_PORT HARNESS_TUNNEL_SSH_USER; do
  if [[ -n "${!key:-}" ]]; then
    ENV_KEYS_PRESENT+=("$key")
  fi
done

SERVICES_TO_START=(vllm-server litellm deepseek-harness)
if [[ "$ENABLE_TUNNELS" == "true" ]]; then
  SERVICES_TO_START+=(litellm-tunnel deepseek-harness-tunnel log-shipper)
fi

if $DRY_RUN; then
  echo "[dry-run] Source stack dir:    $STACK_SRC_DIR"
  echo "[dry-run] Target mode:         $TARGET_MODE${SSH_HOST:+ ($SSH_HOST)}"
  echo "[dry-run] Remote stack dir:    $REMOTE_STACK_DIR"
  echo "[dry-run] Mode:                $($RESUME && echo 'resume (boot hook)' || echo 'pipeline deploy')"
  echo "[dry-run] Reverse tunnels:     $ENABLE_TUNNELS"
  echo "[dry-run] Services:            ${SERVICES_TO_START[*]}"
  echo "[dry-run] Env keys provided:   ${ENV_KEYS_PRESENT[*]:-(none)}"
  [[ "$TARGET_MODE" == "controller-ssh" ]] && echo "[dry-run] Step 1: gpu-wait-ssh $WAIT_TIMEOUT_SEC"
  echo "[dry-run] Step 2: Wait for the VM startup script$($RESUME || echo ' and a running boot hook'); restore reverse-tunnel/, deepseek-harness/, vllm-cache/, huggingface/ from the GCS cache into empty targets"
  echo "[dry-run] Step 3: Ensure Podman, podman-compose, NVIDIA driver + CDI (/etc/cdi/nvidia.yaml), persistent journal, gpu-gcs-sync timer, /mnt/data storage"
  $RESUME || echo "[dry-run] Step 4: Sync stack files (+ this script under .deploy/) to $REMOTE_STACK_DIR and write mode-0600 .env + tunnel key"
  echo "[dry-run] Step 5: sudo TMPDIR=$DATA_ROOT/containers/tmp podman-compose -f compose.yml up -d --build ${SERVICES_TO_START[*]}"
  echo "[dry-run] Step 6: sudo /usr/local/bin/gpu-gcs-sync --fast (persist stack files + .env to the GCS cache; output redacted)"
  echo "[dry-run] Step 7: wait for model: ${WAIT_FOR_MODEL} (vllm-server /health + one LiteLLM chat, timeout ${MODEL_READY_TIMEOUT_SEC}s)"
  $RESUME || echo "[dry-run] Step 8: publish the boot hook (gs://<cache-bucket>/boot-hook/hook.sh) so the next VM boot resumes this revision"
  exit 0
fi

echo "[deploy] Target mode: $TARGET_MODE${SSH_HOST:+ ($SSH_HOST)}"
echo "[deploy] Syncing env keys (names only): ${ENV_KEYS_PRESENT[*]}"

SSH_WRAPPER=()
RSYNC_RSH=""
if [[ "$TARGET_MODE" == "controller-ssh" ]]; then
  if [[ -x /usr/local/bin/gpu-wait-ssh ]]; then
    echo "[deploy] Waiting up to ${WAIT_TIMEOUT_SEC}s for Spot GPU VM SSH..."
    /usr/local/bin/gpu-wait-ssh "$WAIT_TIMEOUT_SEC"
  fi
  SSH_WRAPPER=(/usr/local/bin/gpu-ssh)
  RSYNC_RSH="/usr/local/bin/gpu-ssh"
elif [[ "$TARGET_MODE" == "ssh" ]]; then
  SSH_ARGS=(-o ConnectTimeout=15 -o ServerAliveInterval=30)
  if [[ -n "${GPU_SSH_PRIVATE_KEY:-}" ]]; then
    TMP_SSH_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_SSH_DIR"' EXIT
    printf '%s\n' "$GPU_SSH_PRIVATE_KEY" > "$TMP_SSH_DIR/id_key"
    chmod 0600 "$TMP_SSH_DIR/id_key"
    SSH_ARGS+=(-i "$TMP_SSH_DIR/id_key" -o IdentitiesOnly=yes)
    if [[ -n "${GPU_SSH_KNOWN_HOSTS:-}" ]]; then
      printf '%s\n' "$GPU_SSH_KNOWN_HOSTS" > "$TMP_SSH_DIR/known_hosts"
      SSH_ARGS+=(-o "UserKnownHostsFile=$TMP_SSH_DIR/known_hosts" -o StrictHostKeyChecking=yes)
    else
      SSH_ARGS+=(-o StrictHostKeyChecking=accept-new)
    fi
  fi
  SSH_WRAPPER=(ssh "${SSH_ARGS[@]}" "$SSH_HOST")
  RSYNC_RSH="ssh ${SSH_ARGS[*]}"
fi

run_target_bash() {
  if [[ "$TARGET_MODE" == "local" ]]; then
    bash -s
  else
    "${SSH_WRAPPER[@]}" "bash -s"
  fi
}

# 1. Bootstrap GPU host prerequisites idempotently (Podman, podman-compose, NVIDIA CDI, /mnt/data storage).
{
  printf 'DATA_ROOT=%q\n' "$DATA_ROOT"
  printf 'REMOTE_STACK_DIR=%q\n' "$REMOTE_STACK_DIR"
  printf 'RESUME=%q\n' "$RESUME"
  cat <<'BOOTSTRAP_EOF'
set -euo pipefail

# On a freshly (re)created GCE VM the startup script starts this runner before it finishes (and before it starts the
# boot hook), so a queued deploy can begin in the middle of it. Wait for it, then for a running boot hook (which runs
# this same script with --resume): two deploys must never drive Podman at the same time.
for _ in $(seq 1 180); do
  pgrep -f google_metadata_script_runner >/dev/null 2>&1 || break
  echo "[bootstrap] Waiting for the VM startup script to finish before touching Podman..."
  sleep 10
done
if [[ "$RESUME" != "true" ]]; then
  waited=0
  while systemctl is-active --quiet gpu-boot-hook.service 2>/dev/null; do
    (( waited % 300 == 0 )) && echo "[bootstrap] Waiting for the boot hook (resume of the last deploy) to finish ($(( waited / 60 )) min)..."
    sleep 10; waited=$(( waited + 10 ))
  done
fi

# Fresh VM (stateless MIG): restore what the gpu-gcs-sync timer saved to the regional GCS cache, before anything uses
# it. Only into empty targets (no non-empty file yet), so newer local state is never overwritten. gcloud output is
# dropped: it prints gs://<bucket> paths and the bucket name embeds the GCP project ID (public Actions log).
CACHE_BUCKET=""
[[ -r /etc/gpu-cache-bucket ]] && . /etc/gpu-cache-bucket
gcs_restore() {
  local prefix="$1" dst="$2"
  [[ -n "$(sudo find "$dst" -type f ! -empty -print -quit 2>/dev/null)" ]] && return 1
  echo "[bootstrap] Restoring ${prefix}/ from the GCS cache bucket onto the fresh disk..."
  sudo mkdir -p "$dst"
  if sudo gcloud storage rsync -r "gs://${CACHE_BUCKET}/${prefix}" "$dst" >/dev/null 2>&1; then
    echo "[bootstrap] Restored ${prefix}/ ($(sudo du -sh "$dst" 2>/dev/null | cut -f1))."
  else
    echo "[bootstrap] Nothing restored for ${prefix}/ (not in the GCS cache yet)."
    return 1
  fi
}
if [[ -n "$CACHE_BUCKET" ]] && command -v gcloud >/dev/null 2>&1; then
  gcs_restore reverse-tunnel "${DATA_ROOT}/reverse-tunnel" || true
  if gcs_restore deepseek-harness "${DATA_ROOT}/deepseek-harness"; then
    sudo chown -R 1000:1000 "${DATA_ROOT}/deepseek-harness/dsh-home" "${DATA_ROOT}/deepseek-harness/workspace" 2>/dev/null || true
  fi
  gcs_restore vllm-cache "${DATA_ROOT}/vllm-cache" || true
  if gcs_restore huggingface "${DATA_ROOT}/huggingface"; then
    # gcloud stores the HF cache's snapshot symlinks as plain copies; gpu-gcs-sync saves a manifest to relink them.
    sudo python3 - "${DATA_ROOT}/huggingface" <<'PY' || true
import os, sys
root = os.path.normpath(sys.argv[1])
manifest = os.path.join(root, ".gcs-symlinks.tsv")
restored = 0
if os.path.isfile(manifest):
    with open(manifest, encoding="utf-8") as fh:
        for line in fh:
            rel, sep, target = line.rstrip("\n").partition("\t")
            if not sep:
                continue
            link = os.path.normpath(os.path.join(root, rel))
            if not link.startswith(root + os.sep):
                continue
            if not os.path.exists(os.path.normpath(os.path.join(os.path.dirname(link), target))):
                continue
            os.makedirs(os.path.dirname(link), exist_ok=True)
            if os.path.islink(link) and os.readlink(link) == target:
                continue
            if os.path.isdir(link) and not os.path.islink(link):
                continue
            if os.path.lexists(link):
                os.unlink(link)
            os.symlink(target, link)
            restored += 1
print(f"[bootstrap] Relinked {restored} Hugging Face cache symlinks from the manifest.")
PY
  fi
fi

sudo mkdir -p \
  "${DATA_ROOT}/containers/storage" \
  "${DATA_ROOT}/containers/tmp" \
  "${DATA_ROOT}/huggingface" \
  "${DATA_ROOT}/vllm-cache" \
  "${DATA_ROOT}/deepseek-harness/dsh-home" \
  "${DATA_ROOT}/deepseek-harness/workspace" \
  "${DATA_ROOT}/reverse-tunnel/state/litellm" \
  "${DATA_ROOT}/reverse-tunnel/state/harness" \
  "${DATA_ROOT}/reverse-tunnel/state/logs" \
  "${REMOTE_STACK_DIR}/.deploy"
sudo chmod 0700 "${DATA_ROOT}/reverse-tunnel"
# Directories only (like the VM startup-script): the containers' users must be able to create files in these bind
# mounts. Never recursive: `chmod -R 1777` made dsh-home/.credentials.yaml world-readable and dsh refuses to start
# with it ("credentials-local: ... readable beyond its owner (mode 777)"); live it crash-looped 1388 times.
sudo chmod 1777 \
  "${DATA_ROOT}/deepseek-harness" "${DATA_ROOT}/deepseek-harness/dsh-home" "${DATA_ROOT}/deepseek-harness/workspace" \
  "${DATA_ROOT}/reverse-tunnel/state" "${DATA_ROOT}/reverse-tunnel/state/litellm" "${DATA_ROOT}/reverse-tunnel/state/harness" \
  "${DATA_ROOT}/reverse-tunnel/state/logs"
# Repair files the old recursive chmod opened up: the harness state (credentials, sessions) is owner-only.
sudo find "${DATA_ROOT}/deepseek-harness/dsh-home" -type f -perm /1077 -exec chmod go-rwx,-t {} + 2>/dev/null || true
[[ -f "${DATA_ROOT}/deepseek-harness/dsh-home/.credentials.yaml" ]] && sudo chmod 0600 "${DATA_ROOT}/deepseek-harness/dsh-home/.credentials.yaml"
sudo touch "${DATA_ROOT}/reverse-tunnel/known_hosts"
# Large readahead on the disk behind DATA_ROOT: vLLM loads the checkpoint through mmap page faults, which with the
# default 128 KiB readahead become ~20 KiB reads and pin the disk at its IOPS cap (76 MB/s measured); 16 MiB gave
# ~92 KiB reads and 4.7x faster model loading. Same setting as the startup-script in development/infra/gcp/main.tf.
DATA_SRC="$(findmnt -no SOURCE --target "${DATA_ROOT}" 2>/dev/null || true)"
if [[ -n "$DATA_SRC" && -b "$DATA_SRC" ]]; then
  DATA_BLK="$(lsblk -ndo PKNAME "$DATA_SRC" 2>/dev/null || true)"
  [[ -n "$DATA_BLK" ]] || DATA_BLK="$(basename "$(readlink -f "$DATA_SRC")")"
  echo 16384 | sudo tee "/sys/block/${DATA_BLK}/queue/read_ahead_kb" >/dev/null 2>&1 || true
  echo "[bootstrap] ${DATA_ROOT} on ${DATA_BLK}: read_ahead_kb=$(cat "/sys/block/${DATA_BLK}/queue/read_ahead_kb" 2>/dev/null || echo '?')"
fi
sudo chmod 0644 "${DATA_ROOT}/reverse-tunnel/known_hosts"
sudo chown -R "$(id -u):$(id -g)" "${REMOTE_STACK_DIR}"

# Point Podman storage to /mnt/data before any image pulls so the small boot disk never fills.
sudo mkdir -p /etc/containers
if [[ ! -f /etc/containers/storage.conf ]] || ! grep -q "${DATA_ROOT}/containers/storage" /etc/containers/storage.conf; then
  cat <<STORAGE_EOF | sudo tee /etc/containers/storage.conf >/dev/null
[storage]
driver = "overlay"
graphroot = "${DATA_ROOT}/containers/storage"
runroot = "/run/containers/storage"
STORAGE_EOF
fi

HOST_PKGS=(podman podman-compose netavark aardvark-dns uidmap slirp4netns fuse-overlayfs curl gpg ca-certificates rsync)
if ! dpkg -s "${HOST_PKGS[@]}" >/dev/null 2>&1; then
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq --no-install-recommends "${HOST_PKGS[@]}"
fi

# Container DNS: Ubuntu's Podman 4.9 falls back to the CNI backend without a DNS plugin, so containers cannot
# resolve each other (litellm -> vllm-server, tunnels -> litellm: "connect_to litellm: unknown host"). Use netavark
# + aardvark-dns. Hosts still on CNI get the stack's containers and network recreated once (images are kept).
# Same setting as the GPU VM startup-script in development/infra/gcp/main.tf.
sudo mkdir -p /etc/containers/containers.conf.d
NETAVARK_CONF=/etc/containers/containers.conf.d/50-personal-infra-netavark.conf
NETAVARK_WANT=$'# Managed by personal-infra (development/scripts/deploy_gpu_stack.sh)\n[network]\nnetwork_backend = "netavark"\n'
if [[ "$(sudo cat "$NETAVARK_CONF" 2>/dev/null)"$'\n' != "$NETAVARK_WANT" ]]; then
  printf '%s' "$NETAVARK_WANT" | sudo tee "$NETAVARK_CONF" >/dev/null
fi
if sudo podman network exists gpu-dev-net 2>/dev/null && \
   [[ "$(sudo podman network inspect gpu-dev-net --format '{{.DNSEnabled}}' 2>/dev/null)" != "true" ]]; then
  echo "[bootstrap] Recreating the stack on the netavark backend (gpu-dev-net had no DNS)..."
  for c in deepseek-harness-tunnel litellm-tunnel deepseek-harness litellm vllm-server ray-server; do
    sudo timeout 300 podman rm -f -t 10 "$c" >/dev/null 2>&1 || true
  done
  sudo podman network rm -f gpu-dev-net >/dev/null 2>&1 || true
fi
echo "[bootstrap] Podman network backend: $(sudo podman info --format '{{.Host.NetworkBackend}}')"

# Podman caps every container at 2048 tasks by default; vLLM's 4 TP workers on a 192-vCPU host exceed that right
# after loading the model (ThreadPoolBuildError / EAGAIN) and the container restart-loops. podman-compose 1.0.6
# ignores `pids_limit`, so raise the default for new containers here (also in the VM startup-script, main.tf).
PIDS_CONF=/etc/containers/containers.conf.d/51-personal-infra-pids.conf
PIDS_WANT=$'# Managed by personal-infra (development/scripts/deploy_gpu_stack.sh)\n[containers]\npids_limit = 65536\n'
if [[ "$(sudo cat "$PIDS_CONF" 2>/dev/null)"$'\n' != "$PIDS_WANT" ]]; then
  printf '%s' "$PIDS_WANT" | sudo tee "$PIDS_CONF" >/dev/null
fi

# log-shipper streams this host's journal to the log host: keep the journal persistent and have container output go
# to it (Podman's default when the journal is available; pinned so vLLM's log is always shipped). New containers only.
if [[ ! -d /var/log/journal ]]; then
  sudo mkdir -p /var/log/journal
  sudo systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
  sudo systemctl restart systemd-journald || true
fi
# Move this boot's runtime journal (/run/log/journal: the startup script, the boot hook) to disk, where log-shipper
# reads it; without this, everything logged before the journal became persistent is never shipped.
sudo journalctl --flush >/dev/null 2>&1 || true
LOGDRV_CONF=/etc/containers/containers.conf.d/52-personal-infra-logs.conf
LOGDRV_WANT=$'# Managed by personal-infra (development/scripts/deploy_gpu_stack.sh)\n[containers]\nlog_driver = "journald"\n'
if [[ "$(sudo cat "$LOGDRV_CONF" 2>/dev/null)"$'\n' != "$LOGDRV_WANT" ]]; then
  printf '%s' "$LOGDRV_WANT" | sudo tee "$LOGDRV_CONF" >/dev/null
fi

# gpu-gcs-sync: saves what a recreated VM needs to the regional GCS cache (restored above on a fresh disk): stack
# files + .env + this script (phase 1, --fast: after every deploy, on shutdown) and the HF + JIT caches (phase 2,
# every 15 min). Runner credentials are the startup script's job.
if [[ -n "$CACHE_BUCKET" ]]; then
  sudo tee /usr/local/bin/gpu-gcs-sync >/dev/null <<'SYNCEOF'
#!/usr/bin/env bash
# Managed by personal-infra (development/scripts/deploy_gpu_stack.sh).
set -uo pipefail
export HOME="/root"
export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
FAST_MODE=false
[[ "${1:-}" == "--fast" ]] && FAST_MODE=true
[[ -f /etc/gpu-cache-bucket ]] && . /etc/gpu-cache-bucket
[[ -n "${CACHE_BUCKET:-}" ]] || { echo "[gpu-gcs-sync] CACHE_BUCKET is not configured; skipping."; exit 0; }
command -v gcloud >/dev/null 2>&1 || { echo "[gpu-gcs-sync] gcloud not found; skipping."; exit 0; }
mountpoint -q /mnt/data || { echo "[gpu-gcs-sync] /mnt/data is not mounted; skipping."; exit 0; }

# gcloud's per-file progress is dropped (it floods the shipped journal every 15 min); failures are named, and the exit
# status is non-zero when any sync failed.
sync_dir() {  # LOCAL_DIR REMOTE_PREFIX [gcloud rsync flags...]
  gcloud storage rsync -r "${@:3}" "$1" "gs://${CACHE_BUCKET}/$2" >/dev/null 2>&1 && return 0
  echo "[gpu-gcs-sync] Sync of $1 failed."
  return 1
}
fail=0

# Phase 1: stack files + .env, reverse-tunnel key, harness state (small).
(
  flock -n 9 || { echo "[gpu-gcs-sync] Small-state sync already running; skipping."; exit 0; }
  rc=0
  for d in stacks/gpu-dev-machine reverse-tunnel deepseek-harness; do
    if [[ -n "$(ls -A "/mnt/data/$d" 2>/dev/null)" ]]; then
      sync_dir "/mnt/data/$d" "$d" -c || rc=1
    fi
  done
  exit "$rc"
) 9>/run/gpu-gcs-sync.lock || fail=1
if [[ "$FAST_MODE" == "true" ]]; then
  echo "[gpu-gcs-sync] Fast sync done ($([[ $fail -eq 0 ]] && echo ok || echo 'with failures'))."
  exit "$fail"
fi

# Phase 2: Hugging Face cache (blobs + a manifest of its snapshot symlinks) and the compile/JIT caches.
(
  flock -n 8 || { echo "[gpu-gcs-sync] Cache sync already running; skipping."; exit 0; }
  rc=0
  if [[ -n "$(ls -A /mnt/data/huggingface 2>/dev/null)" ]]; then
    python3 - /mnt/data/huggingface <<'PY' || true
import os, sys
root = sys.argv[1]
entries = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d != ".locks"]
    for name in filenames + dirnames:
        full = os.path.join(dirpath, name)
        if os.path.islink(full):
            entries.append((os.path.relpath(full, root), os.readlink(full)))
if entries:
    tmp, dst = os.path.join(root, ".gcs-symlinks.tsv.tmp"), os.path.join(root, ".gcs-symlinks.tsv")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(f"{rel}\t{target}\n" for rel, target in sorted(entries))
    os.replace(tmp, dst)
PY
    # No -c: checksum mode re-reads the ~475 GiB checkpoint on every run; HF blobs are immutable, size + mtime suffice.
    sync_dir /mnt/data/huggingface huggingface \
      --exclude='(^|.*/)\.locks/.*|.*\.incomplete$|.*\.gcs-symlinks\.tsv\.tmp$' || rc=1
  fi
  if [[ -n "$(ls -A /mnt/data/vllm-cache 2>/dev/null)" ]]; then
    sync_dir /mnt/data/vllm-cache vllm-cache || rc=1
  fi
  exit "$rc"
) 8>/run/gpu-gcs-sync-hf.lock || fail=1
echo "[gpu-gcs-sync] Full sync done ($([[ $fail -eq 0 ]] && echo ok || echo 'with failures'))."
exit "$fail"
SYNCEOF
  sudo chmod 0755 /usr/local/bin/gpu-gcs-sync
  printf '%s\n' '[Unit]' 'Description=Sync GPU VM stack state and model caches to the regional GCS cache bucket' \
    'After=network-online.target' 'Wants=network-online.target' '' '[Service]' 'Type=oneshot' \
    'ExecStart=/usr/local/bin/gpu-gcs-sync' | sudo tee /etc/systemd/system/gpu-gcs-sync.service >/dev/null
  printf '%s\n' '[Unit]' 'Description=Sync GPU VM state to the GCS cache every 15 minutes' '' '[Timer]' \
    'OnBootSec=15min' 'OnUnitActiveSec=15min' 'RandomizedDelaySec=60' '' '[Install]' 'WantedBy=timers.target' \
    | sudo tee /etc/systemd/system/gpu-gcs-sync.timer >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable --now gpu-gcs-sync.timer >/dev/null 2>&1 || echo "[warn] Could not enable gpu-gcs-sync.timer."
fi

if ! nvidia-smi >/dev/null 2>&1; then
  echo "[bootstrap] Installing Ubuntu prebuilt NVIDIA Open Kernel GPU driver..."
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq --no-install-recommends ubuntu-drivers-common
  OPEN_DRV="$(sudo ubuntu-drivers list --gpgpu 2>/dev/null | tr ',' '\n' | grep -Eo 'nvidia-driver-[0-9]+(-server)?-open' | sort -V | tail -n 1 || true)"
  if [[ -n "$OPEN_DRV" ]]; then
    DRV_SUFFIX="${OPEN_DRV#nvidia-driver-}"
    KMOD_PKG="linux-modules-nvidia-${DRV_SUFFIX}-$(uname -r)"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$OPEN_DRV" "$KMOD_PKG" || \
      sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$OPEN_DRV" || \
      sudo ubuntu-drivers install --gpgpu
  else
    sudo ubuntu-drivers install --gpgpu || sudo ubuntu-drivers install
  fi
  sudo modprobe nvidia nvidia-uvm nvidia-modeset || true
fi

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  echo "[bootstrap] Installing NVIDIA Container Toolkit for Podman CDI..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq nvidia-container-toolkit
fi

sudo mkdir -p /etc/cdi
# Podman < 5 (Ubuntu 24.04 ships 4.9.3) bundles CDI library v0.6.x, which only accepts specs up to
# cdiVersion 0.6.0 and silently skips newer ones ("unresolvable CDI devices nvidia.com/gpu=all"). nvidia-ctk
# emits 0.7.0 only for the v0.7.0 fields additionalGids/intelRdt (render-node groups, not needed by CUDA), so
# drop those and declare 0.6.0. JSON is valid YAML, so the path stays /etc/cdi/nvidia.yaml.
# Same conversion as the GPU VM startup-script in development/infra/gcp/main.tf.
PODMAN_MAJOR="$(podman --version | grep -oE '[0-9]+' | head -n1)"
sudo python3 - /etc/cdi/nvidia.yaml "${PODMAN_MAJOR:-4}" <<'PY'
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
BOOTSTRAP_EOF
} | run_target_bash

# 2. Sync stack definitions (Dockerfiles, compose.yml, configs) to the GPU machine, plus this script under .deploy/
# (saved to the GCS cache with the stack, so the boot hook can --resume this exact revision). Resume deploys in place.
if ! $RESUME; then
  if [[ "$TARGET_MODE" == "local" ]]; then
    rsync -az --delete --exclude='.env' --exclude='.deploy/' "$STACK_SRC_DIR/" "$REMOTE_STACK_DIR/"
    install -m 0755 "$SCRIPT_DIR/deploy_gpu_stack.sh" "$REMOTE_STACK_DIR/.deploy/deploy_gpu_stack.sh"
  else
    rsync -az --delete --exclude='.env' --exclude='.deploy/' -e "$RSYNC_RSH" "$STACK_SRC_DIR/" "${SSH_HOST}:${REMOTE_STACK_DIR}/"
    rsync -az -e "$RSYNC_RSH" "$SCRIPT_DIR/deploy_gpu_stack.sh" "${SSH_HOST}:${REMOTE_STACK_DIR}/.deploy/deploy_gpu_stack.sh"
  fi
fi

# 3. Write .env (0600), tunnel SSH key (0444 inside 0700 dir), and start containers via podman-compose.
# Note: All model & vLLM parameters live directly in `compose.yml` (vllm-server command).
# Resume keeps the .env (and tunnel key) restored from the GCS cache: they hold what the last pipeline wrote, and the
# GitHub secrets read below do not exist at boot (set -u aborted on LITELLM_MASTER_KEY in the first bench resume).
ENV_B64=""
if ! $RESUME; then
ENV_CONTENT="$(cat <<EOF
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
HARNESS_USER=${HARNESS_USER:-admin}
HARNESS_PASSWORD=${HARNESS_PASSWORD:-}
HF_TOKEN=${HF_TOKEN:-}
HF_CACHE_DIR=${DATA_ROOT}/huggingface
VLLM_CACHE_DIR=${DATA_ROOT}/vllm-cache
HARNESS_DATA_DIR=${DATA_ROOT}/deepseek-harness/dsh-home
HARNESS_WORKSPACE_DIR=${DATA_ROOT}/deepseek-harness/workspace
TUNNEL_STATE_DIR=${DATA_ROOT}/reverse-tunnel/state
TUNNEL_SSH_HOST=${TUNNEL_SSH_HOST:-}
TUNNEL_SSH_PORT=${TUNNEL_SSH_PORT:-22}
TUNNEL_SSH_USER=${TUNNEL_SSH_USER:-}
TUNNEL_SSH_KEY_FILE=${DATA_ROOT}/reverse-tunnel/id_ed25519
TUNNEL_KNOWN_HOSTS_FILE=${DATA_ROOT}/reverse-tunnel/known_hosts
TUNNEL_BIND_ADDRESS=${TUNNEL_BIND_ADDRESS:-127.0.0.1}
REMOTE_LITELLM_PORT=${REMOTE_LITELLM_PORT:-4000}
REMOTE_HARNESS_PORT=${REMOTE_HARNESS_PORT:-3080}
LITELLM_TUNNEL_SSH_HOST=${LITELLM_TUNNEL_SSH_HOST:-${TUNNEL_SSH_HOST:-}}
LITELLM_TUNNEL_SSH_PORT=${LITELLM_TUNNEL_SSH_PORT:-${TUNNEL_SSH_PORT:-22}}
LITELLM_TUNNEL_SSH_USER=${LITELLM_TUNNEL_SSH_USER:-${TUNNEL_SSH_USER:-}}
HARNESS_TUNNEL_SSH_HOST=${HARNESS_TUNNEL_SSH_HOST:-${TUNNEL_SSH_HOST:-}}
HARNESS_TUNNEL_SSH_PORT=${HARNESS_TUNNEL_SSH_PORT:-${TUNNEL_SSH_PORT:-22}}
HARNESS_TUNNEL_SSH_USER=${HARNESS_TUNNEL_SSH_USER:-${TUNNEL_SSH_USER:-}}
LOG_SSH_HOST=${LOG_SSH_HOST:-${TUNNEL_SSH_HOST:-}}
LOG_SSH_PORT=${LOG_SSH_PORT:-${TUNNEL_SSH_PORT:-22}}
LOG_SSH_USER=${LOG_SSH_USER:-gpulog}
LOG_STREAM=${LOG_STREAM:-gpu-vm}
EOF
)"

ENV_B64="$(printf '%s\n' "$ENV_CONTENT" | base64 -w0)"
fi
TUNNEL_KEY_B64=""
if [[ -n "${TUNNEL_SSH_PRIVATE_KEY:-}" ]]; then
  TUNNEL_KEY_B64="$(printf '%s\n' "$TUNNEL_SSH_PRIVATE_KEY" | base64 -w0)"
fi
TUNNEL_KH_B64=""
if [[ -n "${TUNNEL_KNOWN_HOSTS:-}" ]]; then
  TUNNEL_KH_B64="$(printf '%s\n' "$TUNNEL_KNOWN_HOSTS" | base64 -w0)"
fi

{
  printf 'DATA_ROOT=%q\n' "$DATA_ROOT"
  printf 'REMOTE_STACK_DIR=%q\n' "$REMOTE_STACK_DIR"
  printf 'ENABLE_TUNNELS=%q\n' "$ENABLE_TUNNELS"
  printf 'WAIT_FOR_MODEL=%q\n' "$WAIT_FOR_MODEL"
  printf 'MODEL_READY_TIMEOUT_SEC=%q\n' "$MODEL_READY_TIMEOUT_SEC"
  printf 'ENV_B64=%q\n' "$ENV_B64"
  printf 'TUNNEL_KEY_B64=%q\n' "$TUNNEL_KEY_B64"
  printf 'TUNNEL_KH_B64=%q\n' "$TUNNEL_KH_B64"
  cat <<'DEPLOY_EOF'
set -euo pipefail

umask 077
if [[ -n "$ENV_B64" ]]; then
  printf '%s' "$ENV_B64" | base64 -d > "${REMOTE_STACK_DIR}/.env"
fi
chmod 0600 "${REMOTE_STACK_DIR}/.env"

if [[ -n "$TUNNEL_KEY_B64" ]]; then
  printf '%s' "$TUNNEL_KEY_B64" | base64 -d | sudo tee "${DATA_ROOT}/reverse-tunnel/id_ed25519" >/dev/null
  sudo chmod 0644 "${DATA_ROOT}/reverse-tunnel/id_ed25519"
else
  sudo touch "${DATA_ROOT}/reverse-tunnel/id_ed25519"
  sudo chmod 0644 "${DATA_ROOT}/reverse-tunnel/id_ed25519"
fi

if [[ -n "$TUNNEL_KH_B64" ]]; then
  printf '%s' "$TUNNEL_KH_B64" | base64 -d | sudo tee "${DATA_ROOT}/reverse-tunnel/known_hosts" >/dev/null
  sudo chmod 0644 "${DATA_ROOT}/reverse-tunnel/known_hosts"
fi

cd "${REMOTE_STACK_DIR}"
# The model server used to be the Ray Serve `ray-server` container; make sure a leftover one cannot hold
# the GPUs or port 8000.
sudo podman rm -f ray-server >/dev/null 2>&1 || true
expected=(vllm-server litellm deepseek-harness)
compose_services=()   # empty = every service in compose.yml
if [[ "$ENABLE_TUNNELS" == "true" ]]; then
  expected+=(litellm-tunnel deepseek-harness-tunnel log-shipper)
  echo "[deploy] Building and starting all 6 services (reverse SSH tunnels + log-shipper included) with podman-compose..."
else
  echo "[deploy] Reverse tunnels disabled; starting vllm-server, litellm, and deepseek-harness..."
  sudo podman rm -f litellm-tunnel deepseek-harness-tunnel log-shipper >/dev/null 2>&1 || true
  compose_services=(vllm-server litellm deepseek-harness)
fi
compose_up() { sudo env TMPDIR="${DATA_ROOT}/containers/tmp" podman-compose -f compose.yml up -d --build "${compose_services[@]}"; }
not_running_list() {
  local name state
  for name in "${expected[@]}"; do
    state="$(sudo podman inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
    [[ "$state" == "running" ]] || printf '%s=%s ' "$name" "$state"
  done
}

# Every container podman-compose creates carries the config hash of compose.yml; after a good `up` they all match.
config_hashes() {
  local name
  for name in "${expected[@]}"; do
    sudo podman inspect -f '{{index .Config.Labels "io.podman.compose.config-hash"}}' "$name" 2>/dev/null || echo missing
  done | sort -u
}
# Stop and remove the stack's containers, waiting out slow exits: a killed vLLM releases ~200 GiB of pinned host
# memory (28 min while the disk was saturated by the download), longer than podman waits.
teardown_stack() {
  local name state
  for name in "${expected[@]}" litellm-tunnel deepseek-harness-tunnel log-shipper; do
    sudo timeout 120 podman stop -t 30 "$name" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 120); do
    state="$(sudo podman ps -a --format '{{.Names}} {{.State}}' | awk '$2=="stopping" || $2=="running" {printf "%s ", $1}')"
    [[ -z "$state" ]] && break
    echo "[deploy] Waiting for containers to stop: ${state}"
    sleep 15
  done
  for name in "${expected[@]}" litellm-tunnel deepseek-harness-tunnel log-shipper; do
    sudo podman rm -f "$name" >/dev/null 2>&1 || true
  done
}

compose_up
# When compose.yml changed, podman-compose recreates the stack, but if the old vllm-server is still exiting, its
# removal fails, `podman run` hits "name already in use" and podman-compose falls back to `podman start`, which
# revives the OLD container (seen: v0.33.0 kept running after the image moved to v0.34.0). Detect a mixed or failed
# stack and converge from a clean teardown.
if [[ -n "$(not_running_list)" || "$(config_hashes | wc -l)" -ne 1 ]]; then
  echo "[deploy] Stack did not converge (stale or stopped containers); tearing down and starting again..."
  teardown_stack
  compose_up
fi

if [[ -x /usr/local/bin/gpu-gcs-sync ]]; then
  echo "[deploy] Persisting freshly deployed stack config to regional GCS cache bucket (gpu-gcs-sync --fast)..."
  # gcloud prints every gs://<bucket> path and the bucket name embeds the GCP project ID, which must not reach the
  # (public) Actions log: keep the output, print a count, and redact bucket names if something has to be shown.
  if sync_out="$(sudo /usr/local/bin/gpu-gcs-sync --fast 2>&1)"; then
    echo "[ok] Stack files, .env and the deploy script are saved in the GCS cache bucket."
  else
    sync_rc=$?
    echo "[warn] gpu-gcs-sync --fast exited ${sync_rc}; the gpu-gcs-sync timer retries. Last lines (bucket redacted):"
    sed -E 's#gs://[^/[:space:]]+#gs://<cache-bucket>#g' <<<"${sync_out}" | tail -n 5 | sed 's/^/    /'
  fi
fi

echo "[deploy] Active Podman containers:"
sudo podman ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

# podman-compose 1.0.x exits 0 even when a build or `podman run` fails, so verify the result explicitly.
read -r -a not_running <<<"$(not_running_list)"
if (( ${#not_running[@]} )); then
  echo "[error] podman-compose finished, but these containers are not running: ${not_running[*]}" >&2
  echo "[error] See the build/start errors above." >&2
  exit 1
fi
if [[ "$(config_hashes | wc -l)" -ne 1 ]]; then
  echo "[error] Containers run different compose.yml revisions (a stale container survived): $(config_hashes | tr '\n' ' ')" >&2
  exit 1
fi
echo "[ok] All ${#expected[@]} containers are running the current compose.yml (vllm-server may still be loading the model; see its healthcheck)."
echo "[deploy] vllm-server image: $(sudo podman inspect -f '{{.ImageName}}' vllm-server 2>/dev/null)"

# A tunnel that cannot connect still looks "running" for a moment: autossh exits when the first ssh attempt
# fails within its gate time and podman restarts it. Let them settle, then require no restarts.
if [[ "$ENABLE_TUNNELS" == "true" ]]; then
  sleep 45
  bad_tunnels=()
  for name in litellm-tunnel deepseek-harness-tunnel; do
    info="$(sudo podman inspect -f '{{.State.Status}} {{.RestartCount}}' "$name" 2>/dev/null || echo "missing ?")"
    echo "[deploy] ${name}: state/restarts = ${info}; last log lines:"
    sudo podman logs --tail 5 "$name" 2>&1 | sed 's/^/    /' || true
    [[ "$info" == "running 0" ]] || bad_tunnels+=("$name")
  done
  if (( ${#bad_tunnels[@]} )); then
    echo "[error] Reverse tunnels are not holding a connection: ${bad_tunnels[*]} (see the log lines above)." >&2
    exit 1
  fi
  echo "[ok] Reverse tunnels are up and stable."
  # Logs are auxiliary: a log host that refuses the stream (e.g. its gpulog user is not set up yet) only warns.
  if sudo podman logs log-shipper 2>&1 | grep -q 'connection to the log host ended'; then
    echo "[warn] log-shipper cannot stream to the log host (set it up with cloud/scripts/bootstrap_vm.py --tunnel-pubkey-file); last lines:"
    sudo podman logs --tail 4 log-shipper 2>&1 | sed 's/^/    /' || true
  else
    echo "[ok] log-shipper is streaming this VM's journal to the log host (/var/log/gpu-dev/ there)."
  fi
fi

# "Running" containers do not mean a serving model: vLLM loads ~475 GiB first, and failures after the load (CUDA graph
# capture, thread limits) only surface minutes later as a restart loop. Wait for /health, fail fast with the root-cause
# lines if vllm-server restarts or exits, then send one chat request through LiteLLM (what the tunnels expose).
if [[ "${WAIT_FOR_MODEL,,}" =~ ^(1|true|yes|on)$ ]]; then
  echo "[deploy] Waiting up to ${MODEL_READY_TIMEOUT_SEC}s for vllm-server to load the model and serve..."
  restarts0="$(sudo podman inspect -f '{{.RestartCount}}' vllm-server 2>/dev/null || echo 0)"
  started=$SECONDS; last_report=$SECONDS
  # Exception messages from the vLLM log, deduplicated and without the "(Worker_TP0 pid=..) ERROR <ts> [file:line]"
  # prefixes. The worker's own exception (the root cause) precedes a long EngineCore traceback, so a plain tail misses it.
  read -r -d '' VLLM_EXC_FILTER <<'PY' || true
import re, sys
prefix = re.compile(r"^\((?P<src>[^) ]+)[^)]*\)\s+(?:ERROR|WARNING|INFO|DEBUG)\s+\S+\s+\S+\s+\[[^\]]*\]\s?")
exc = re.compile(r"^(?:[A-Za-z_][\w.]*\.)?\w*(?:Error|Exception|Interrupt)\b(?::|$)")
found = []
for raw in sys.stdin.read().replace("\r", "\n").splitlines():
    m = prefix.match(raw)
    src = m.group("src") + ": " if m else ""
    body = prefix.sub("", raw).strip()
    if exc.match(body) or "out of memory" in body.lower() or body.startswith("Killed"):
        # Per-request IDs (e.g. Hugging Face's) would defeat the deduplication of one repeating error.
        found.append(src + re.sub(r"\s*\(Request ID: [^)]*\)", "", body))
uniq = []
for f in found:
    if f not in uniq:
        uniq.append(f)
for f in uniq[-15:]:
    print("    " + f[:400])
PY
  # No SSH into the (stateless MIG) VM: everything needed to debug a failed start has to land in this log.
  vllm_diag() {
    local hub=/mnt/data/huggingface/hub
    echo "[diag] GPUs: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | sort | uniq -c | tr -s ' ' | paste -sd ';' || echo '?')"
    echo "[diag] HF cache ${hub}: $(sudo du -sh "$hub" 2>/dev/null | cut -f1 || echo '?'); snapshot *.safetensors: $(sudo find "$hub" -path '*/snapshots/*' -name '*.safetensors' 2>/dev/null | wc -l)" \
      "(symlinks: $(sudo find "$hub" -path '*/snapshots/*' -name '*.safetensors' -type l 2>/dev/null | wc -l)," \
      "broken: $(sudo find "$hub" -path '*/snapshots/*' -xtype l 2>/dev/null | wc -l)); *.incomplete: $(sudo find "$hub" -name '*.incomplete' 2>/dev/null | wc -l)"
    echo "[diag] vllm-cache: $(sudo du -sh "${VLLM_CACHE_DIR:-/mnt/data/vllm-cache}" 2>/dev/null | cut -f1 || echo '?')"
    echo "[diag] VM startup script, this boot (bucket redacted):"
    sudo journalctl -u google-startup-scripts.service -b --no-pager -o cat 2>/dev/null \
      | grep -E '\[(bootstrap|warn)\]|Restored|ERROR|rror:' | sed -E 's#gs://[^/[:space:]]+#gs://<cache-bucket>#g' \
      | tail -n 15 | cut -c1-250 | sed 's/^/    /' || true
    echo "[diag] vllm-server exceptions (deduplicated, newest last):"
    sudo podman logs --tail 4000 vllm-server 2>&1 | python3 -c "$VLLM_EXC_FILTER" \
      | sed -E 's#gs://[^/[:space:]]+#gs://<cache-bucket>#g' || true
  }
  while [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8000/health 2>/dev/null)" != "200" ]]; do
    info="$(sudo podman inspect -f '{{.State.Status}} {{.RestartCount}}' vllm-server 2>/dev/null || echo "missing ?")"
    if [[ "$info" != "running ${restarts0}" ]]; then
      echo "[error] vllm-server stopped or restarted while starting (state/restarts: ${info}, was running ${restarts0})." >&2
      vllm_diag >&2
      exit 1
    fi
    if (( SECONDS - started > MODEL_READY_TIMEOUT_SEC )); then
      echo "[error] vllm-server did not become healthy within ${MODEL_READY_TIMEOUT_SEC}s; last log lines:" >&2
      sudo podman logs --tail 10 vllm-server 2>&1 | tr '\r' '\n' | tail -10 | cut -c1-200 >&2 || true
      vllm_diag >&2
      exit 1
    fi
    if (( SECONDS - last_report >= 300 )); then
      echo "[deploy] ...still starting after $(( (SECONDS - started) / 60 )) min: $(sudo podman logs --tail 3 vllm-server 2>&1 | tr '\r' '\n' | grep -v '^\s*$' | tail -1 | cut -c1-140 || true)"
      last_report=$SECONDS
    fi
    sleep 20
  done
  echo "[ok] vllm-server is healthy after $(( (SECONDS - started) / 60 )) min."
  # /health answering on the host while podman's in-container healthcheck keeps failing points at the container
  # itself (e.g. its pids limit exhausted, so `podman exec` cannot fork): show podman's last check result and PIDs.
  hc_status="$(sudo podman inspect -f '{{.State.Health.Status}}' vllm-server 2>/dev/null || true)"
  if [[ -n "$hc_status" && "$hc_status" != "healthy" && "$hc_status" != "starting" ]]; then
    echo "[warn] /health answers 200 but podman marks vllm-server '${hc_status}' (PIDs: $(sudo podman stats --no-stream --format '{{.PIDs}}' vllm-server 2>/dev/null || echo ?)); last healthcheck results:"
    sudo podman inspect -f '{{range .State.Health.Log}}exit={{.ExitCode}} {{.Output}}{{"\n"}}{{end}}' vllm-server 2>/dev/null \
      | tr '\r' ' ' | grep -v '^\s*$' | tail -n 2 | cut -c1-300 | sed 's/^/    /' || true
  fi
  # DeepSeek V4.1 reasons before answering; a budget too small for the reasoning leaves message.content null
  # (finish_reason "length"). Any completion proves the model serves end to end through LiteLLM.
  master_key="$(sed -n 's/^LITELLM_MASTER_KEY=//p' .env | head -n1)"
  reply="$(printf 'Authorization: Bearer %s\n' "$master_key" | curl -s --max-time 900 -H @- -H 'Content-Type: application/json' \
    http://127.0.0.1:4000/v1/chat/completions \
    -d '{"model": "deepseek-v4.1-flash", "messages": [{"role": "user", "content": "Reply with exactly: ok"}], "max_tokens": 256}' \
    | python3 -c 'import json, sys
try:
    r = json.load(sys.stdin)
except ValueError:
    sys.exit("LiteLLM returned no JSON (not reachable?)")
choices = r.get("choices") or []
if not choices:
    sys.exit("no completion: " + json.dumps(r)[:300])
choice = choices[0]
msg = choice.get("message") or {}
text = (msg.get("content") or "").strip()
if not text:
    reasoning = msg.get("reasoning_content") or msg.get("reasoning") or ""
    text = "(no final text: finish_reason=%s, %d reasoning chars)" % (choice.get("finish_reason"), len(reasoning))
print(text[:120].replace("\n", " "))')" || {
    echo "[error] LiteLLM -> vllm-server chat check failed: ${reply}" >&2
    exit 1
  }
  echo "[ok] Chat completion through LiteLLM (deepseek-v4.1-flash): ${reply}"
fi

# The harness tunnel can be up while `dsh web` is not: socat on :3080 then has nothing behind it. Any HTTP answer
# (401 without the per-process login token is expected) means it serves. Its log carries that login token in the
# startup URL, so only redacted lines may reach this (public) log.
harness_code="000"
for _ in $(seq 1 18); do
  harness_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3080/ 2>/dev/null || true)"
  [[ "$harness_code" != "000" ]] && break
  sleep 10
done
harness_diag() {
  echo "[error] deepseek-harness: $(sudo podman inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} started={{.State.StartedAt}} error={{.State.Error}}' deepseek-harness 2>/dev/null || echo missing)" >&2
  echo "[error] Last log lines (URLs/tokens redacted):" >&2
  sudo podman logs --tail 40 deepseek-harness 2>&1 | tr '\r' '\n' \
    | sed -E 's#[a-zA-Z][a-zA-Z0-9+.-]*://[^[:space:]]+#<url redacted>#g; s#[A-Za-z0-9_+/=-]{24,}#<redacted>#g' | cut -c1-240 >&2 || true
}
if [[ "$harness_code" == "000" ]]; then
  echo "[error] deepseek-harness is not answering on :3080." >&2
  harness_diag
  exit 1
fi
# It must stay up: live, it answered once and then exited without being restarted for minutes.
harness_started="$(sudo podman inspect -f '{{.State.StartedAt}}' deepseek-harness 2>/dev/null || true)"
sleep 90
harness_code2="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3080/ 2>/dev/null || true)"
if [[ "$harness_code2" == "000" || "$(sudo podman inspect -f '{{.State.Status}} {{.State.StartedAt}}' deepseek-harness 2>/dev/null)" != "running ${harness_started}" ]]; then
  echo "[error] deepseek-harness answered once (HTTP ${harness_code}) but did not stay up (now HTTP ${harness_code2})." >&2
  harness_diag
  exit 1
fi
# /login must ask for the password and, with it, redirect to the tokenized URL (never printed: it is a credential).
harness_password="$(sed -n 's/^HARNESS_PASSWORD=//p' .env | head -n1)"
if [[ -n "$harness_password" ]]; then
  harness_user="$(sed -n 's/^HARNESS_USER=//p' .env | head -n1)"
  no_auth="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3080/login 2>/dev/null || true)"
  with_auth="$(printf 'user = "%s:%s"\n' "${harness_user:-admin}" "$harness_password" \
    | curl -s -K - -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 http://127.0.0.1:3080/login 2>/dev/null || true)"
  if [[ "$no_auth" != "401" || "${with_auth%% *}" != "302" || "${with_auth#* }" != *"/?token="* ]]; then
    echo "[error] harness /login check failed: without password HTTP ${no_auth} (want 401), with password HTTP ${with_auth%% *} (want 302 to /?token=...)." >&2
    harness_diag
    exit 1
  fi
  echo "[ok] deepseek-harness answers on :3080 (HTTP ${harness_code}); /login asks for the password and hands out the current launch token."
else
  echo "[ok] deepseek-harness answers on :3080 (HTTP ${harness_code}); set HARNESS_PASSWORD to enable /login, or use the 'dsh web:' URL from its log."
fi
DEPLOY_EOF
} | run_target_bash

# 4. Publish the boot hook (pipeline deploys only, after every check above passed): the next VM boot re-deploys this
# revision from the GCS cache. The startup script disarms it before running it and re-arms it only on success.
if ! $RESUME; then
  {
    printf 'HOOK_REV=%q\n' "${GITHUB_SHA:-manual}"
    printf 'REMOTE_STACK_DIR=%q\n' "$REMOTE_STACK_DIR"
    cat <<'PUBLISH_EOF'
set -euo pipefail
if [[ ! -r /etc/gpu-cache-bucket ]]; then
  echo "[deploy] No GCS cache bucket on this host (not the GCP MIG); no boot hook published."
  exit 0
fi
. /etc/gpu-cache-bucket
HOOKS="gs://${CACHE_BUCKET}/boot-hook"
# Immutable snapshot of exactly what was just deployed and verified (compose files, .env, this script). The hook
# restores only this snapshot, so a later pipeline that fails (its files already synced to stacks/) can never be
# resumed: the previous hook keeps pointing at the previous good snapshot.
SNAP="stack-$(date -u +%Y%m%dT%H%M%SZ)-${HOOK_REV:0:7}"
if ! sudo gcloud storage rsync -r "${REMOTE_STACK_DIR}" "${HOOKS}/${SNAP}" >/dev/null 2>&1; then
  echo "[warn] Could not snapshot the stack to the GCS cache; boot hook not updated (the previous one stays)."
  exit 0
fi
hook="$(mktemp)"
{
  printf '#!/usr/bin/env bash\n'
  printf '# Boot hook published by development/scripts/deploy_gpu_stack.sh after the successful deploy of %s (%s).\n' \
    "${HOOK_REV}" "$(date -u +%FT%TZ)"
  printf 'SNAP=%q\n' "${SNAP}"
  cat <<'HOOK'
# Run once per boot by the VM startup script (gpu-boot-hook.service), re-armed only when it exits 0: restore the
# snapshot of the stack (files + .env + deploy script) that deploy saved to the GCS cache, then redeploy it with --resume.
set -euo pipefail
. /etc/gpu-cache-bucket
STACK_DIR=/mnt/data/stacks/gpu-dev-machine
mkdir -p "$STACK_DIR"
timeout 600 gcloud storage rsync -r --delete-unmatched-destination-objects \
  "gs://${CACHE_BUCKET}/boot-hook/${SNAP}" "$STACK_DIR" >/dev/null 2>&1
chmod 0600 "$STACK_DIR/.env"
exec bash "$STACK_DIR/.deploy/deploy_gpu_stack.sh" --resume
HOOK
} > "$hook"
if sudo gcloud storage cp "$hook" "${HOOKS}/hook.sh" >/dev/null 2>&1; then
  sudo gcloud storage rm "${HOOKS}/running.sh" "${HOOKS}/failed.sh" "${HOOKS}/attempts" >/dev/null 2>&1 || true
  # Older snapshots are unreachable now (running.sh / failed.sh were their only users).
  { sudo gcloud storage ls "${HOOKS}/" 2>/dev/null | grep -E '/stack-[^/]+/$' | grep -vF "/${SNAP}/" \
    | while read -r old; do sudo gcloud storage rm -r "$old" >/dev/null 2>&1 || true; done; } || true
  echo "[ok] Boot hook published: the next VM boot resumes ${HOOK_REV:0:7} (disarmed if that fails, until the next pipeline)."
else
  echo "[warn] Could not publish the boot hook; the previous one (if any) stays."
fi
rm -f "$hook"
PUBLISH_EOF
  } | run_target_bash
fi
