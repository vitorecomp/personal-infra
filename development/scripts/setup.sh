#!/usr/bin/env bash
# Configures and manages the persistent GitHub Actions self-hosted runner on a
# deployed GPU controller/host across `gcp`, `azure`, or `on-prem`.
#
# When `--provider=gcp` (and `--host` is not overriding), connects via
# `gcloud compute ssh --tunnel-through-iap` (no public ingress required).
# For `azure` / `on-prem`, connects over standard `ssh`.
#
# Usage:
#   ./development/scripts/setup.sh --provider=gcp --repo=vitorecomp/<repo> --token=<TOKEN>
#   ./development/scripts/setup.sh --provider=gcp --repo=vitorecomp/<repo> --dry-run
#   ./development/scripts/setup.sh --provider=gcp --status
#   ./development/scripts/setup.sh --provider=on-prem --host=dev@192.168.1.50 --repo=vitorecomp/<repo> --token=<TOKEN>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEV_ROOT/.." && pwd)"

PROVIDER="${PROVIDER:-}"
HOST_TARGET="${DEPLOY_HOST:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-}"
PROJECT_ID="${PROJECT_ID:-}"
ZONE="${ZONE:-}"
INSTANCE_NAME="${INSTANCE_NAME:-}"

REPO_SPEC="${GITHUB_REPO:-}"
RUNNER_TOKEN_VAL="${RUNNER_TOKEN:-}"
RUNNER_PAT_VAL="${RUNNER_PAT:-}"
RUNNER_NAME="${RUNNER_NAME:-}"
RUNNER_LABELS="${RUNNER_LABELS:-}"
RUNNER_USER="${RUNNER_USER:-}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
WORK_DIR="${RUNNER_WORK_DIR:-_work}"

MODE="configure"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: ./development/scripts/setup.sh --provider=<gcp|azure|on-prem> [options]

Target Selection:
  --provider=PROVIDER           Target provider: gcp, azure, or on-prem
  --project=PROJECT_ID          GCP project override (defaults to active gcloud project)
  --zone=ZONE                   GCP controller zone override (resolved from Terraform / gcloud when omitted)
  --instance=NAME               GCP controller VM name override (default: dev-gpu-controller)
  --host=USER@HOST              Explicit SSH target (for on-prem / azure, or custom SSH override)
  --ssh-key=PATH                SSH private key path override
  --known-hosts=PATH            SSH known_hosts file override (non-GCP SSH)

Runner Registration Options:
  --repo=OWNER/REPO             GitHub repository (e.g. vitorecomp/my-repo or https://github.com/vitorecomp/my-repo)
  --url=URL                     Alias for --repo with a full GitHub URL
  --token=TOKEN                 Runner registration token from Repo -> Settings -> Actions -> Runners (or env RUNNER_TOKEN)
  --pat=PAT                     Alternative: Fine-Grained PAT with repo Administration Read/Write (or env RUNNER_PAT)
  --name=NAME                   Runner name in GitHub (default: <provider>-gpu-controller)
  --labels=L1,L2,...            Comma-separated labels (default: self-hosted,linux,x64,<provider>-gpu)
  --runner-user=USER            Non-root OS user for the runner service (default: github-runner)
  --runner-dir=DIR              Runner install directory on target host (default: /opt/actions-runner)
  --work-dir=DIR                Runner work folder (default: _work)

Modes:
  --status                      Show current GitHub runner systemd service status on the target machine
  --remove                      Stop, uninstall systemd service, and unregister the runner (uses --token or --pat)
  --dry-run                     Print resolved transport and remote setup steps without connecting
  -h, --help                    Show this help message
EOF
}

require_arg() {
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    echo "[error] $1 requires a non-empty value" >&2
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider=*) PROVIDER="${1#*=}"; shift ;;
    --provider) require_arg "$1" "${2:-}"; PROVIDER="$2"; shift 2 ;;
    --project=*) PROJECT_ID="${1#*=}"; shift ;;
    --project) require_arg "$1" "${2:-}"; PROJECT_ID="$2"; shift 2 ;;
    --zone=*) ZONE="${1#*=}"; shift ;;
    --zone) require_arg "$1" "${2:-}"; ZONE="$2"; shift 2 ;;
    --instance=*) INSTANCE_NAME="${1#*=}"; shift ;;
    --instance) require_arg "$1" "${2:-}"; INSTANCE_NAME="$2"; shift 2 ;;
    --host=*) HOST_TARGET="${1#*=}"; shift ;;
    --host) require_arg "$1" "${2:-}"; HOST_TARGET="$2"; shift 2 ;;
    --ssh-key=*) SSH_KEY_FILE="${1#*=}"; shift ;;
    --ssh-key) require_arg "$1" "${2:-}"; SSH_KEY_FILE="$2"; shift 2 ;;
    --known-hosts=*) KNOWN_HOSTS_FILE="${1#*=}"; shift ;;
    --known-hosts) require_arg "$1" "${2:-}"; KNOWN_HOSTS_FILE="$2"; shift 2 ;;
    --repo=*|--url=*) REPO_SPEC="${1#*=}"; shift ;;
    --repo|--url) require_arg "$1" "${2:-}"; REPO_SPEC="$2"; shift 2 ;;
    --token=*) RUNNER_TOKEN_VAL="${1#*=}"; shift ;;
    --token) require_arg "$1" "${2:-}"; RUNNER_TOKEN_VAL="$2"; shift 2 ;;
    --pat=*) RUNNER_PAT_VAL="${1#*=}"; shift ;;
    --pat) require_arg "$1" "${2:-}"; RUNNER_PAT_VAL="$2"; shift 2 ;;
    --name=*) RUNNER_NAME="${1#*=}"; shift ;;
    --name) require_arg "$1" "${2:-}"; RUNNER_NAME="$2"; shift 2 ;;
    --labels=*) RUNNER_LABELS="${1#*=}"; shift ;;
    --labels) require_arg "$1" "${2:-}"; RUNNER_LABELS="$2"; shift 2 ;;
    --runner-user=*) RUNNER_USER="${1#*=}"; shift ;;
    --runner-user) require_arg "$1" "${2:-}"; RUNNER_USER="$2"; shift 2 ;;
    --runner-dir=*) RUNNER_DIR="${1#*=}"; shift ;;
    --runner-dir) require_arg "$1" "${2:-}"; RUNNER_DIR="$2"; shift 2 ;;
    --work-dir=*) WORK_DIR="${1#*=}"; shift ;;
    --work-dir) require_arg "$1" "${2:-}"; WORK_DIR="$2"; shift 2 ;;
    --status) MODE="status"; shift ;;
    --remove) MODE="remove"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[error] Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$PROVIDER" && -z "$HOST_TARGET" ]]; then
  echo "[error] --provider=<gcp|azure|on-prem> (or --host=user@ip) is required" >&2
  usage >&2
  exit 1
fi

if [[ -n "$PROVIDER" ]]; then
  case "$PROVIDER" in
    gcp) PROVIDER="gcp" ;;
    azure) PROVIDER="azure" ;;
    on-prem|on_prem|onprem) PROVIDER="on-prem" ;;
    *)
      echo "[error] Unsupported provider '$PROVIDER' (expected: gcp, azure, or on-prem)" >&2
      exit 1
      ;;
  esac
fi

EFFECTIVE_TAG="${PROVIDER:-custom}"
RUNNER_NAME="${RUNNER_NAME:-${EFFECTIVE_TAG}-gpu-controller}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,${EFFECTIVE_TAG}-gpu}"

REPO_URL=""
if [[ -n "$REPO_SPEC" ]]; then
  if [[ "$REPO_SPEC" =~ ^https?:// ]]; then
    REPO_URL="${REPO_SPEC%/}"
  else
    REPO_URL="https://github.com/${REPO_SPEC#/}"
  fi
fi

if [[ "$MODE" == "configure" && -z "$REPO_URL" ]]; then
  echo "[error] --repo=<owner/repo> (or --url=https://github.com/<owner>/<repo>) is required to configure the runner" >&2
  exit 1
fi

gcloud_config_value() {
  local prop="$1"
  command -v gcloud >/dev/null 2>&1 || return 0
  local val
  val="$(GCE_METADATA_ROOT=127.0.0.1:1 gcloud config get-value "$prop" 2>/dev/null || true)"
  val="${val//$'\r'/}"
  if [[ "$val" == "(unset)" ]]; then
    val=""
  fi
  printf '%s' "$val"
}

TRANSPORT="ssh"
GCP_PROJECT=""
GCP_CTRL_NAME=""
GCP_CTRL_ZONE=""

if [[ "$PROVIDER" == "gcp" && -z "$HOST_TARGET" ]]; then
  TRANSPORT="gcloud"
  INFRA_DIR="$DEV_ROOT/infra/gcp"
  GCP_PROJECT="${PROJECT_ID:-$(gcloud_config_value project)}"
  GCP_CTRL_NAME="$INSTANCE_NAME"
  GCP_CTRL_ZONE="$ZONE"

  if [[ -z "$SSH_KEY_FILE" && -f "$INFRA_DIR/ssh-key" && -f "$INFRA_DIR/ssh-key.pub" ]]; then
    SSH_KEY_FILE="$INFRA_DIR/ssh-key"
  fi

  tf_bin=()
  if command -v terraform >/dev/null 2>&1; then
    tf_bin=(terraform -chdir="$INFRA_DIR")
  elif command -v mise >/dev/null 2>&1; then
    tf_bin=(mise exec --cd "$REPO_ROOT" -- terraform -chdir="$INFRA_DIR")
  fi

  if [[ ${#tf_bin[@]} -gt 0 && -d "$INFRA_DIR/.terraform" ]]; then
    if [[ -n "$GCP_PROJECT" ]]; then
      "${tf_bin[@]}" workspace select "$GCP_PROJECT" >/dev/null 2>&1 || true
    fi
    [[ -z "$GCP_PROJECT" ]] && GCP_PROJECT="$("${tf_bin[@]}" output -raw project_id 2>/dev/null || true)"
    [[ -z "$GCP_CTRL_NAME" ]] && GCP_CTRL_NAME="$("${tf_bin[@]}" output -raw controller_name 2>/dev/null || true)"
    [[ -z "$GCP_CTRL_ZONE" ]] && GCP_CTRL_ZONE="$("${tf_bin[@]}" output -raw controller_zone 2>/dev/null || true)"
    if [[ -z "$RUNNER_USER" ]]; then
      RUNNER_USER="$("${tf_bin[@]}" output -raw runner_username 2>/dev/null || true)"
    fi
  fi

  GCP_CTRL_NAME="${GCP_CTRL_NAME:-dev-gpu-controller}"

  # Fall back to live gcloud instance lookup if zone wasn't in local Terraform state.
  if [[ -z "$GCP_CTRL_ZONE" && -n "$GCP_PROJECT" ]] && ! $DRY_RUN && command -v gcloud >/dev/null 2>&1; then
    GCP_CTRL_ZONE="$(gcloud compute instances list \
      --project="$GCP_PROJECT" \
      --filter="name=${GCP_CTRL_NAME}" \
      --format="value(zone.basename())" 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -z "$GCP_PROJECT" || -z "$GCP_CTRL_ZONE" ]]; then
    if $DRY_RUN; then
      GCP_PROJECT="${GCP_PROJECT:-<gcloud-active-project>}"
      GCP_CTRL_ZONE="${GCP_CTRL_ZONE:-europe-west4-a}"
    else
      echo "[error] Could not resolve GCP project or controller VM zone (project='${GCP_PROJECT:-<unset>}', instance='${GCP_CTRL_NAME}')." >&2
      echo "[error] Deploy first with './development/scripts/deploy.sh --provider=gcp' or pass --project / --zone." >&2
      exit 1
    fi
  fi
else
  if [[ -n "$PROVIDER" ]]; then
    INFRA_DIR="$DEV_ROOT/infra/$PROVIDER"
    [[ -z "$SSH_KEY_FILE" && -f "$INFRA_DIR/ssh-key" ]] && SSH_KEY_FILE="$INFRA_DIR/ssh-key"
    [[ -z "$KNOWN_HOSTS_FILE" && -f "$INFRA_DIR/known_hosts" ]] && KNOWN_HOSTS_FILE="$INFRA_DIR/known_hosts"

    if [[ -z "$HOST_TARGET" && -d "$INFRA_DIR/.terraform" ]] && command -v terraform >/dev/null 2>&1; then
      host_ip="$(terraform -chdir="$INFRA_DIR" output -raw controller_external_ip 2>/dev/null || terraform -chdir="$INFRA_DIR" output -raw external_ip 2>/dev/null || true)"
      ssh_user="$(terraform -chdir="$INFRA_DIR" output -raw ssh_username 2>/dev/null || true)"
      [[ -n "$host_ip" && -n "$ssh_user" ]] && HOST_TARGET="${ssh_user}@${host_ip}"
    fi
  fi

  if [[ -z "$HOST_TARGET" ]]; then
    if $DRY_RUN; then
      HOST_TARGET="<deployed-${EFFECTIVE_TAG}-controller-user@ip>"
    else
      echo "[error] Could not resolve target SSH host for provider '${PROVIDER:-custom}'. Pass --host=USER@IP." >&2
      exit 1
    fi
  fi
fi

RUNNER_USER="${RUNNER_USER:-github-runner}"

GCLOUD_SSH_CMD=()
SSH_ARGS=()
if [[ "$TRANSPORT" == "gcloud" ]]; then
  GCLOUD_SSH_CMD=(
    gcloud compute ssh "$GCP_CTRL_NAME"
    --project="$GCP_PROJECT"
    --zone="$GCP_CTRL_ZONE"
    --tunnel-through-iap
    --quiet
    --strict-host-key-checking=no
  )
  if [[ -n "$SSH_KEY_FILE" && -f "$SSH_KEY_FILE" && -f "${SSH_KEY_FILE}.pub" ]]; then
    GCLOUD_SSH_CMD+=(--ssh-key-file="$SSH_KEY_FILE")
  fi
else
  SSH_ARGS=(-o ConnectTimeout=15 -o ServerAliveInterval=30)
  [[ -n "$SSH_KEY_FILE" ]] && SSH_ARGS+=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes)
  [[ -n "$KNOWN_HOSTS_FILE" ]] && SSH_ARGS+=(-o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -o StrictHostKeyChecking=yes)
fi

if $DRY_RUN; then
  echo "[dry-run] Mode:                 $MODE"
  echo "[dry-run] Provider:             ${PROVIDER:-custom}"
  if [[ "$TRANSPORT" == "gcloud" ]]; then
    echo "[dry-run] SSH Transport:        gcloud compute ssh $GCP_CTRL_NAME --project=$GCP_PROJECT --zone=$GCP_CTRL_ZONE --tunnel-through-iap"
  else
    echo "[dry-run] SSH Transport:        ssh $HOST_TARGET"
  fi
  echo "[dry-run] Runner User / Dir:    $RUNNER_USER / $RUNNER_DIR"
  if [[ "$MODE" == "configure" ]]; then
    echo "[dry-run] GitHub Repo URL:      $REPO_URL"
    echo "[dry-run] Runner Name:          $RUNNER_NAME"
    echo "[dry-run] Runner Labels:        $RUNNER_LABELS"
    if [[ -n "$RUNNER_PAT_VAL" ]]; then
      echo "[dry-run] Auth Secret:          --pat (<redacted>)"
    elif [[ -n "$RUNNER_TOKEN_VAL" ]]; then
      echo "[dry-run] Auth Secret:          --token (<redacted>)"
    else
      echo "[dry-run] Auth Secret:          (prompt interactively or read RUNNER_TOKEN / RUNNER_PAT)"
    fi
    echo "[dry-run] Remote Steps:"
    echo "[dry-run]   1. Ensure user '$RUNNER_USER', '$RUNNER_DIR', OS/.NET runner packages, and actions-runner binary exist"
    echo "[dry-run]   2. Stop/uninstall any prior systemd runner unit in '$RUNNER_DIR' if re-registering"
    echo "[dry-run]   3. Run 'sudo -u $RUNNER_USER $RUNNER_DIR/config.sh --unattended --url $REPO_URL --name $RUNNER_NAME --labels $RUNNER_LABELS --work $WORK_DIR --replace'"
    echo "[dry-run]   4. Run 'sudo ./svc.sh install $RUNNER_USER && sudo ./svc.sh start && sudo ./svc.sh status'"
  elif [[ "$MODE" == "remove" ]]; then
    echo "[dry-run] Remote Steps:"
    echo "[dry-run]   1. Stop & uninstall systemd runner service in '$RUNNER_DIR'"
    echo "[dry-run]   2. Run 'sudo -u $RUNNER_USER $RUNNER_DIR/config.sh remove'"
  else
    echo "[dry-run] Remote Steps:"
    echo "[dry-run]   Check '$RUNNER_DIR/svc.sh status'"
  fi
  exit 0
fi

run_remote_command() {
  local cmd="$1"
  if [[ "$TRANSPORT" == "gcloud" ]]; then
    gcloud services enable iap.googleapis.com --project="$GCP_PROJECT" --quiet >/dev/null 2>&1 || true
    "${GCLOUD_SSH_CMD[@]}" --command="$cmd"
  else
    ssh "${SSH_ARGS[@]}" "$HOST_TARGET" "$cmd"
  fi
}

run_remote_stdin_script() {
  if [[ "$TRANSPORT" == "gcloud" ]]; then
    gcloud services enable iap.googleapis.com --project="$GCP_PROJECT" --quiet >/dev/null 2>&1 || true
    "${GCLOUD_SSH_CMD[@]}" --ssh-flag="-T" --command="bash -s"
  else
    ssh "${SSH_ARGS[@]}" "$HOST_TARGET" "bash -s"
  fi
}

if [[ "$MODE" == "status" ]]; then
  run_remote_command "cd '$RUNNER_DIR' && sudo ./svc.sh status"
  exit 0
fi

if [[ -z "$RUNNER_TOKEN_VAL" && -z "$RUNNER_PAT_VAL" ]]; then
  if [[ -t 0 ]]; then
    read -rsp "Enter GitHub runner token (from Repo -> Settings -> Actions -> Runners): " RUNNER_TOKEN_VAL
    echo ""
  fi
  if [[ -z "$RUNNER_TOKEN_VAL" && -z "$RUNNER_PAT_VAL" ]]; then
    echo "[error] Provide --token=<TOKEN> (or env RUNNER_TOKEN) or --pat=<PAT> (or env RUNNER_PAT)." >&2
    exit 1
  fi
fi

# Stream configuration variables and script over SSH stdin so neither tokens nor PATs
# appear in remote command-line arguments (`ps aux`) or shell history.
{
  printf 'REMOTE_MODE=%q\n' "$MODE"
  printf 'REMOTE_REPO_URL=%q\n' "$REPO_URL"
  printf 'REMOTE_TOKEN=%q\n' "$RUNNER_TOKEN_VAL"
  printf 'REMOTE_PAT=%q\n' "$RUNNER_PAT_VAL"
  printf 'REMOTE_RUNNER_NAME=%q\n' "$RUNNER_NAME"
  printf 'REMOTE_RUNNER_LABELS=%q\n' "$RUNNER_LABELS"
  printf 'REMOTE_RUNNER_USER=%q\n' "$RUNNER_USER"
  printf 'REMOTE_RUNNER_DIR=%q\n' "$RUNNER_DIR"
  printf 'REMOTE_WORK_DIR=%q\n' "$WORK_DIR"
  cat <<'REMOTE_EOF'
set -euo pipefail

if [[ "$REMOTE_MODE" == "remove" ]]; then
  if [[ ! -d "$REMOTE_RUNNER_DIR" ]]; then
    echo "Runner directory $REMOTE_RUNNER_DIR does not exist; nothing to remove."
    exit 0
  fi
  cd "$REMOTE_RUNNER_DIR"
  if [[ -f .service ]]; then
    sudo ./svc.sh stop || true
    sudo ./svc.sh uninstall || true
  fi
  if [[ -f .runner ]]; then
    if [[ -n "$REMOTE_PAT" ]]; then
      sudo -u "$REMOTE_RUNNER_USER" ./config.sh remove --pat "$REMOTE_PAT"
    else
      sudo -u "$REMOTE_RUNNER_USER" ./config.sh remove --token "$REMOTE_TOKEN"
    fi
  fi
  echo "GitHub Actions runner removed cleanly."
  exit 0
fi

# Wait briefly if cloud-init / startup script is still finishing initial package setup.
for _ in $(seq 1 24); do
  if ! sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

# Ensure required OS/.NET packages exist (no-op on GCP where controller_startup_script pre-installs them).
RUNNER_PACKAGES=(
  ca-certificates curl git git-lfs jq libicu-dev libkrb5-3
  libssl-dev rsync tar unzip xz-utils zip zlib1g
)
if ! dpkg -s "${RUNNER_PACKAGES[@]}" >/dev/null 2>&1; then
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends "${RUNNER_PACKAGES[@]}"
fi

if ! id -u "$REMOTE_RUNNER_USER" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "$REMOTE_RUNNER_USER"
fi
if [[ -f /etc/gpu-ssh/id_ed25519 ]]; then
  RUNNER_HOME="$(getent passwd "$REMOTE_RUNNER_USER" | cut -d: -f6)"
  sudo install -d -m 0700 -o "$REMOTE_RUNNER_USER" -g "$REMOTE_RUNNER_USER" "$RUNNER_HOME/.ssh"
  sudo cp /etc/gpu-ssh/id_ed25519 "$RUNNER_HOME/.ssh/gpu_ed25519"
  sudo chown "$REMOTE_RUNNER_USER:$REMOTE_RUNNER_USER" "$RUNNER_HOME/.ssh/gpu_ed25519"
  sudo chmod 0600 "$RUNNER_HOME/.ssh/gpu_ed25519"
fi

sudo install -d -m 0755 -o "$REMOTE_RUNNER_USER" -g "$REMOTE_RUNNER_USER" "$REMOTE_RUNNER_DIR"

if [[ ! -x "$REMOTE_RUNNER_DIR/config.sh" ]]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) RUNNER_ARCH="x64" ;;
    aarch64|arm64) RUNNER_ARCH="arm64" ;;
    *) echo "[error] Unsupported CPU architecture for actions-runner: $ARCH" >&2; exit 1 ;;
  esac
  LATEST_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/actions/runner/releases/latest)"
  RUNNER_VER="${LATEST_URL##*/v}"
  TMP_TAR="$(mktemp /tmp/actions-runner.XXXXXX.tar.gz)"
  trap 'rm -f "$TMP_TAR"' EXIT
  curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VER}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VER}.tar.gz" -o "$TMP_TAR"
  sudo tar -xzf "$TMP_TAR" -C "$REMOTE_RUNNER_DIR"
  sudo chown -R "$REMOTE_RUNNER_USER:$REMOTE_RUNNER_USER" "$REMOTE_RUNNER_DIR"
  sudo "$REMOTE_RUNNER_DIR/bin/installdependencies.sh" >/dev/null 2>&1 || true
fi

cd "$REMOTE_RUNNER_DIR"

# Stop & uninstall any existing service before re-running config.sh --replace.
if [[ -f .service ]]; then
  sudo ./svc.sh stop || true
  sudo ./svc.sh uninstall || true
fi

AUTH_ARGS=()
if [[ -n "$REMOTE_PAT" ]]; then
  AUTH_ARGS=(--pat "$REMOTE_PAT")
else
  AUTH_ARGS=(--token "$REMOTE_TOKEN")
fi

sudo -u "$REMOTE_RUNNER_USER" ./config.sh \
  --unattended \
  --url "$REMOTE_REPO_URL" \
  "${AUTH_ARGS[@]}" \
  --name "$REMOTE_RUNNER_NAME" \
  --labels "$REMOTE_RUNNER_LABELS" \
  --work "$REMOTE_WORK_DIR" \
  --replace

sudo ./svc.sh install "$REMOTE_RUNNER_USER"
sudo ./svc.sh start
sudo ./svc.sh status
REMOTE_EOF
} | run_remote_stdin_script
