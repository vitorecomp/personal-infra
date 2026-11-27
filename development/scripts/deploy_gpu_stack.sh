#!/usr/bin/env bash
# Deploys the `development/gpu-dev-machine` Podman + `podman-compose` stack onto
# the target GPU machine from a self-hosted GitHub Actions runner (or locally).
#
# Supports three target modes (`--target-mode` / `GPU_TARGET_MODE`):
#   * `local`:          deploys directly on the current GPU host (default on GCP Stateful MIG runner).
#   * `ssh`:            syncs and deploys over standard SSH to `GPU_SSH_HOST`.
#   * `controller-ssh`: syncs and deploys over `/usr/local/bin/gpu-ssh` (`gpu` host alias) if present.
#   * `auto` (default): picks `controller-ssh` if `/usr/local/bin/gpu-ssh` exists,
#                       else `ssh` if `GPU_SSH_HOST` is set, else `local`.
#
# Secret hygiene: secret values are streamed over stdin with mode 0600 and never
# printed to stdout/stderr (preflight logs only variable names).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STACK_SRC_DIR="$DEV_ROOT/gpu-dev-machine"

TARGET_MODE="${GPU_TARGET_MODE:-auto}"
SSH_HOST="${GPU_SSH_HOST:-}"
REMOTE_STACK_DIR="${GPU_REMOTE_STACK_DIR:-/mnt/data/stacks/gpu-dev-machine}"
DATA_ROOT="${GPU_DATA_ROOT:-/mnt/data}"
WAIT_TIMEOUT_SEC="${GPU_WAIT_TIMEOUT_SEC:-600}"
DRY_RUN=false

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
  --dry-run               Print resolved target, synced env key names (never values), and commands without executing
  -h, --help              Show this help message and exit

Environment Secrets / Variables (supplied by `.github/workflows/deploy-gpu-machine.yml`):
  LITELLM_MASTER_KEY      Required Bearer token securing LiteLLM (:4000) and DeepSeek Harness
  HF_TOKEN                Optional Hugging Face read token for model weight downloads
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
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[error] Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

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

if ! $DRY_RUN; then
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
  LITELLM_MASTER_KEY HF_TOKEN \
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
  SERVICES_TO_START+=(litellm-tunnel deepseek-harness-tunnel)
fi

if $DRY_RUN; then
  echo "[dry-run] Source stack dir:    $STACK_SRC_DIR"
  echo "[dry-run] Target mode:         $TARGET_MODE${SSH_HOST:+ ($SSH_HOST)}"
  echo "[dry-run] Remote stack dir:    $REMOTE_STACK_DIR"
  echo "[dry-run] Reverse tunnels:     $ENABLE_TUNNELS"
  echo "[dry-run] Services:            ${SERVICES_TO_START[*]}"
  echo "[dry-run] Env keys provided:   ${ENV_KEYS_PRESENT[*]:-(none)}"
  [[ "$TARGET_MODE" == "controller-ssh" ]] && echo "[dry-run] Step 1: gpu-wait-ssh $WAIT_TIMEOUT_SEC"
  echo "[dry-run] Step 2: Ensure Podman, podman-compose, NVIDIA driver + CDI (/etc/cdi/nvidia.yaml), and /mnt/data storage exist"
  echo "[dry-run] Step 3: Sync stack files to $REMOTE_STACK_DIR and write mode-0600 .env + tunnel key"
  echo "[dry-run] Step 4: sudo TMPDIR=$DATA_ROOT/containers/tmp podman-compose -f compose.yml up -d --build ${SERVICES_TO_START[*]}"
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
  cat <<'BOOTSTRAP_EOF'
set -euo pipefail

sudo mkdir -p \
  "${DATA_ROOT}/containers/storage" \
  "${DATA_ROOT}/containers/tmp" \
  "${DATA_ROOT}/huggingface" \
  "${DATA_ROOT}/deepseek-harness/dsh-home" \
  "${DATA_ROOT}/deepseek-harness/workspace" \
  "${DATA_ROOT}/reverse-tunnel/state/litellm" \
  "${DATA_ROOT}/reverse-tunnel/state/harness" \
  "${REMOTE_STACK_DIR}"
sudo chmod 0700 "${DATA_ROOT}/reverse-tunnel"
sudo chmod -R 1777 "${DATA_ROOT}/deepseek-harness" "${DATA_ROOT}/reverse-tunnel/state"
sudo touch "${DATA_ROOT}/reverse-tunnel/known_hosts"
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

HOST_PKGS=(podman podman-compose uidmap slirp4netns fuse-overlayfs curl gpg ca-certificates rsync)
if ! dpkg -s "${HOST_PKGS[@]}" >/dev/null 2>&1; then
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq --no-install-recommends "${HOST_PKGS[@]}"
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

# 2. Sync stack definitions (Dockerfiles, compose.yml, configs) to the GPU machine.
if [[ "$TARGET_MODE" == "local" ]]; then
  rsync -az --delete --exclude='.env' "$STACK_SRC_DIR/" "$REMOTE_STACK_DIR/"
else
  rsync -az --delete --exclude='.env' -e "$RSYNC_RSH" "$STACK_SRC_DIR/" "${SSH_HOST}:${REMOTE_STACK_DIR}/"
fi

# 3. Write .env (0600), tunnel SSH key (0444 inside 0700 dir), and start containers via podman-compose.
# Note: All model & vLLM parameters live directly in `compose.yml` (vllm-server command).
ENV_CONTENT="$(cat <<EOF
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
HF_TOKEN=${HF_TOKEN:-}
HF_CACHE_DIR=${DATA_ROOT}/huggingface
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
EOF
)"

ENV_B64="$(printf '%s\n' "$ENV_CONTENT" | base64 -w0)"
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
  printf 'ENV_B64=%q\n' "$ENV_B64"
  printf 'TUNNEL_KEY_B64=%q\n' "$TUNNEL_KEY_B64"
  printf 'TUNNEL_KH_B64=%q\n' "$TUNNEL_KH_B64"
  cat <<'DEPLOY_EOF'
set -euo pipefail

umask 077
printf '%s' "$ENV_B64" | base64 -d > "${REMOTE_STACK_DIR}/.env"
chmod 0600 "${REMOTE_STACK_DIR}/.env"

if [[ -n "$TUNNEL_KEY_B64" ]]; then
  printf '%s' "$TUNNEL_KEY_B64" | base64 -d | sudo tee "${DATA_ROOT}/reverse-tunnel/id_ed25519" >/dev/null
  sudo chmod 0644 "${DATA_ROOT}/reverse-tunnel/id_ed25519"
else
  sudo touch "${DATA_ROOT}/reverse-tunnel/id_ed25519"
fi

if [[ -n "$TUNNEL_KH_B64" ]]; then
  printf '%s' "$TUNNEL_KH_B64" | base64 -d | sudo tee "${DATA_ROOT}/reverse-tunnel/known_hosts" >/dev/null
  sudo chmod 0644 "${DATA_ROOT}/reverse-tunnel/known_hosts"
fi

cd "${REMOTE_STACK_DIR}"
# The model server used to be the Ray Serve `ray-server` container; make sure a leftover one cannot hold
# the GPUs or port 8000.
sudo podman rm -f ray-server >/dev/null 2>&1 || true
if [[ "$ENABLE_TUNNELS" == "true" ]]; then
  echo "[deploy] Building and starting all 5 services (including reverse SSH tunnels) with podman-compose..."
  sudo env TMPDIR="${DATA_ROOT}/containers/tmp" podman-compose -f compose.yml up -d --build
else
  echo "[deploy] Reverse tunnels disabled; starting vllm-server, litellm, and deepseek-harness..."
  sudo podman rm -f litellm-tunnel deepseek-harness-tunnel >/dev/null 2>&1 || true
  sudo env TMPDIR="${DATA_ROOT}/containers/tmp" podman-compose -f compose.yml up -d --build vllm-server litellm deepseek-harness
fi

echo "[deploy] Active Podman containers:"
sudo podman ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

# podman-compose 1.0.x exits 0 even when a build or `podman run` fails, so verify the result explicitly.
expected=(vllm-server litellm deepseek-harness)
[[ "$ENABLE_TUNNELS" == "true" ]] && expected+=(litellm-tunnel deepseek-harness-tunnel)
not_running=()
for name in "${expected[@]}"; do
  state="$(sudo podman inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
  [[ "$state" == "running" ]] || not_running+=("${name}=${state}")
done
if (( ${#not_running[@]} )); then
  echo "[error] podman-compose finished, but these containers are not running: ${not_running[*]}" >&2
  echo "[error] See the build/start errors above." >&2
  exit 1
fi
echo "[ok] All ${#expected[@]} containers are running (vllm-server may still be loading the model; see its healthcheck)."

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
fi
DEPLOY_EOF
} | run_target_bash
