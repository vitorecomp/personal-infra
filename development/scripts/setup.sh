#!/usr/bin/env bash
# Syncs `development/.env` to GitHub Repository & `gpu` Environment variables/secrets
# via `gh`, and manages GitHub Actions self-hosted runners across providers.
#
# Provider modes:
#   * GCP (`--provider=gcp`, zero SSH):
#       - Default (`configure`): generates missing `__generate__` secrets locally,
#         persists them to `development/.env` (mode 0600), and syncs GitHub Repo
#         Variables + `gpu` Environment Secrets/Variables (`GPU_TARGET_MODE=local`).
#         The GCP Stateful MIG self-registers its runner on boot via Secret Manager
#         when provisioned with `./development/scripts/deploy.sh --provider=gcp`.
#       - `--status`: inspects registered GitHub runners via `gh api` and, if
#         `gcloud` is available, prints managed instances for the GCP Stateful MIG.
#       - `--remove`: unregisters matching runner(s) directly via `gh api -X DELETE`.
#   * Azure / On-Prem / Explicit `--host=USER@IP` (SSH mode):
#       - Syncs `development/.env` to GitHub and installs/checks/removes the
#         persistent `actions-runner` systemd service over SSH.
#
# Usage:
#   ./development/scripts/setup.sh --provider=gcp --dry-run
#   ./development/scripts/setup.sh --provider=gcp
#   ./development/scripts/setup.sh --provider=gcp --status
#   ./development/scripts/setup.sh --provider=gcp --remove
#   ./development/scripts/setup.sh --provider=on-prem --host=dev@192.0.2.10

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEV_ROOT/.." && pwd)"

ENV_FILE="$DEV_ROOT/.env"
EXPLICIT_ENV_FILE=false

# Capture any pre-set caller environment overrides before loading `.env`
CALLER_PROVIDER="${PROVIDER:-}"
CALLER_HOST_TARGET="${DEPLOY_HOST:-}"
CALLER_SSH_KEY_FILE="${SSH_KEY_FILE:-}"
CALLER_KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-}"
CALLER_PROJECT_ID="${PROJECT_ID:-}"
CALLER_ZONE="${ZONE:-}"
CALLER_MIG_NAME="${MIG_NAME:-}"
CALLER_NAME_PREFIX="${NAME_PREFIX:-}"
CALLER_REPO_SPEC="${GITHUB_REPO:-}"
CALLER_RUNNER_TOKEN="${RUNNER_TOKEN:-}"
CALLER_RUNNER_PAT="${RUNNER_PAT:-}"
CALLER_RUNNER_NAME="${RUNNER_NAME:-}"
CALLER_RUNNER_LABELS="${RUNNER_LABELS:-}"
CALLER_RUNNER_USER="${RUNNER_USER:-}"
CALLER_RUNNER_DIR="${RUNNER_DIR:-}"
CALLER_WORK_DIR="${RUNNER_WORK_DIR:-}"

CLI_PROVIDER=""
CLI_HOST_TARGET=""
CLI_SSH_KEY_FILE=""
CLI_KNOWN_HOSTS_FILE=""
CLI_PROJECT_ID=""
CLI_ZONE=""
CLI_MIG_NAME=""
CLI_NAME_PREFIX=""
CLI_REPO_SPEC=""
CLI_GITHUB_ENV=""
CLI_RUNNER_TOKEN=""
CLI_RUNNER_PAT=""
CLI_RUNNER_NAME=""
CLI_RUNNER_LABELS=""
CLI_RUNNER_USER=""
CLI_RUNNER_DIR=""
CLI_WORK_DIR=""

MODE="configure"
SYNC_GITHUB=true
SYNC_GITHUB_ONLY=false
CLI_TRIGGER_DEPLOY=""
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: ./development/scripts/setup.sh --provider=<gcp|azure|on-prem> [options]

Reads configuration from `development/.env` (or --env-file=PATH), generates any
`__generate__` secrets locally, syncs GitHub Repository & Environment variables
and secrets via `gh`, and manages self-hosted runner lifecycle.

On GCP (`--provider=gcp` without `--host`), this script is 100% SSH-free:
  - Default mode syncs GitHub variables/secrets; the Stateful MIG GPU VM
    self-registers its runner automatically on boot via Secret Manager.
  - `--status` queries GitHub Actions runners via `gh api` + GCP MIG instances.
  - `--remove` deletes matching runner registration(s) via `gh api`.

Target Selection:
  --provider=PROVIDER           Target provider: gcp, azure, or on-prem
  --env-file=PATH               Path to .env file (default: development/.env)
  --project=PROJECT_ID          GCP project override for `--status` MIG inspection
  --zone=ZONE                   GCP zone override for `--status` MIG inspection
  --mig=NAME                    GCP MIG name override for `--status` (default: <prefix>-mig)
  --name-prefix=PREFIX          GCP resource prefix override (default: dev-gpu)
  --host=USER@HOST              Explicit SSH target (enables SSH runner setup for on-prem/azure)
  --ssh-key=PATH                SSH private key path override (SSH mode only)
  --known-hosts=PATH            SSH known_hosts file override (SSH mode only)

GitHub & Runner Options (override `development/.env`):
  --repo=OWNER/REPO             GitHub repository (default: GITHUB_REPO in .env, else vitorecomp/personal-infra)
  --github-env=NAME             GitHub Environment name for stack secrets/vars (default: gpu)
  --token=TOKEN                 Explicit runner registration/removal token (SSH mode; auto-minted via `gh api` when omitted)
  --pat=PAT                     Fine-Grained PAT with repo Administration Read/Write (SSH mode)
  --name=NAME                   Runner name in GitHub (default: RUNNER_NAME in .env, else <provider>-gpu-runner)
  --labels=L1,L2,...            Comma-separated runner labels (default: self-hosted,linux,x64,<GPU_RUNNER>)
  --runner-user=USER            Non-root OS user for the runner service in SSH mode (default: github-runner)
  --runner-dir=DIR              Runner install directory on SSH host (default: /opt/actions-runner)
  --work-dir=DIR                Runner work folder on SSH host (default: _work)

Modes & Flags:
  --sync-github-only            Only sync `development/.env` variables/secrets to GitHub via `gh`
  --skip-github-sync            Skip `gh variable/secret set` (SSH mode: only configure remote runner)
  --trigger-deploy              Dispatch `gh workflow run deploy-gpu-machine.yml` after setup completes
  --status                      GCP: query `gh api` runners & MIG instances (zero SSH); SSH mode: check remote systemd service
  --remove                      GCP: unregister matching runner(s) via `gh api` (zero SSH); SSH mode: stop & remove remote service
  --dry-run                     Print resolved `gh` / API / SSH steps without mutating anything
  -h, --help                    Show this help message and exit

Examples:
  # Preview GitHub sync on GCP (zero SSH, safe read-only):
  ./development/scripts/setup.sh --provider=gcp --dry-run

  # Generate secrets in development/.env and sync GitHub Repo & `gpu` Environment:
  ./development/scripts/setup.sh --provider=gcp

  # Check self-hosted runner online/offline state & GCP Stateful MIG instances (zero SSH):
  ./development/scripts/setup.sh --provider=gcp --status

  # Delete offline/stale GCP runner registration(s) via GitHub API (zero SSH):
  ./development/scripts/setup.sh --provider=gcp --remove

  # Sync GitHub settings and install the runner over SSH on an on-prem host:
  ./development/scripts/setup.sh --provider=on-prem --host=dev@192.0.2.10
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
    --provider=*) CLI_PROVIDER="${1#*=}"; shift ;;
    --provider) require_arg "$1" "${2:-}"; CLI_PROVIDER="$2"; shift 2 ;;
    --env-file=*) ENV_FILE="${1#*=}"; EXPLICIT_ENV_FILE=true; shift ;;
    --env-file) require_arg "$1" "${2:-}"; ENV_FILE="$2"; EXPLICIT_ENV_FILE=true; shift 2 ;;
    --project=*) CLI_PROJECT_ID="${1#*=}"; shift ;;
    --project) require_arg "$1" "${2:-}"; CLI_PROJECT_ID="$2"; shift 2 ;;
    --zone=*) CLI_ZONE="${1#*=}"; shift ;;
    --zone) require_arg "$1" "${2:-}"; CLI_ZONE="$2"; shift 2 ;;
    --mig=*) CLI_MIG_NAME="${1#*=}"; shift ;;
    --mig) require_arg "$1" "${2:-}"; CLI_MIG_NAME="$2"; shift 2 ;;
    --name-prefix=*) CLI_NAME_PREFIX="${1#*=}"; shift ;;
    --name-prefix) require_arg "$1" "${2:-}"; CLI_NAME_PREFIX="$2"; shift 2 ;;
    --host=*) CLI_HOST_TARGET="${1#*=}"; shift ;;
    --host) require_arg "$1" "${2:-}"; CLI_HOST_TARGET="$2"; shift 2 ;;
    --ssh-key=*) CLI_SSH_KEY_FILE="${1#*=}"; shift ;;
    --ssh-key) require_arg "$1" "${2:-}"; CLI_SSH_KEY_FILE="$2"; shift 2 ;;
    --known-hosts=*) CLI_KNOWN_HOSTS_FILE="${1#*=}"; shift ;;
    --known-hosts) require_arg "$1" "${2:-}"; CLI_KNOWN_HOSTS_FILE="$2"; shift 2 ;;
    --repo=*|--url=*) CLI_REPO_SPEC="${1#*=}"; shift ;;
    --repo|--url) require_arg "$1" "${2:-}"; CLI_REPO_SPEC="$2"; shift 2 ;;
    --github-env=*) CLI_GITHUB_ENV="${1#*=}"; shift ;;
    --github-env) require_arg "$1" "${2:-}"; CLI_GITHUB_ENV="$2"; shift 2 ;;
    --token=*) CLI_RUNNER_TOKEN="${1#*=}"; shift ;;
    --token) require_arg "$1" "${2:-}"; CLI_RUNNER_TOKEN="$2"; shift 2 ;;
    --pat=*) CLI_RUNNER_PAT="${1#*=}"; shift ;;
    --pat) require_arg "$1" "${2:-}"; CLI_RUNNER_PAT="$2"; shift 2 ;;
    --name=*) CLI_RUNNER_NAME="${1#*=}"; shift ;;
    --name) require_arg "$1" "${2:-}"; CLI_RUNNER_NAME="$2"; shift 2 ;;
    --labels=*) CLI_RUNNER_LABELS="${1#*=}"; shift ;;
    --labels) require_arg "$1" "${2:-}"; CLI_RUNNER_LABELS="$2"; shift 2 ;;
    --runner-user=*) CLI_RUNNER_USER="${1#*=}"; shift ;;
    --runner-user) require_arg "$1" "${2:-}"; CLI_RUNNER_USER="$2"; shift 2 ;;
    --runner-dir=*) CLI_RUNNER_DIR="${1#*=}"; shift ;;
    --runner-dir) require_arg "$1" "${2:-}"; CLI_RUNNER_DIR="$2"; shift 2 ;;
    --work-dir=*) CLI_WORK_DIR="${1#*=}"; shift ;;
    --work-dir) require_arg "$1" "${2:-}"; CLI_WORK_DIR="$2"; shift 2 ;;
    --sync-github-only) SYNC_GITHUB_ONLY=true; shift ;;
    --skip-github-sync) SYNC_GITHUB=false; shift ;;
    --trigger-deploy) CLI_TRIGGER_DEPLOY="true"; shift ;;
    --status) MODE="status"; SYNC_GITHUB=false; shift ;;
    --remove) MODE="remove"; SYNC_GITHUB=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[error] Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Safely parse key=value lines from `development/.env` without executing shell code.
declare -A DOTENV=()
load_dotenv_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  if ! $DRY_RUN; then
    chmod 600 "$path" 2>/dev/null || true
  fi
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do
    DOTENV["$k"]="$v"
  done < <(
    python3 - "$path" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip()
        if len(v) >= 2 and ((v[0] == v[-1] == '"') or (v[0] == v[-1] == "'")):
            v = v[1:-1]
        elif " #" in v:
            v = v.split(" #", 1)[0].strip()
        sys.stdout.write(f"{k}\0{v}\0")
PY
  )
}

if $EXPLICIT_ENV_FILE && [[ ! -f "$ENV_FILE" ]]; then
  echo "[error] Specified --env-file does not exist: $ENV_FILE" >&2
  exit 1
fi
load_dotenv_file "$ENV_FILE"

env_or_dotenv() {
  local key="$1"
  local default_val="${2:-}"
  if [[ -n "${!key:-}" ]]; then
    printf '%s' "${!key}"
  elif [[ -n "${DOTENV[$key]:-}" ]]; then
    printf '%s' "${DOTENV[$key]}"
  else
    printf '%s' "$default_val"
  fi
}

expand_tilde() {
  local p="$1"
  if [[ "$p" == "~" ]]; then
    printf '%s' "$HOME"
  elif [[ "$p" == "~/"* ]]; then
    printf '%s/%s' "$HOME" "${p#"~/"}"
  else
    printf '%s' "$p"
  fi
}

PROVIDER="${CLI_PROVIDER:-${CALLER_PROVIDER:-${DOTENV[PROVIDER]:-}}}"
HOST_TARGET="${CLI_HOST_TARGET:-${CALLER_HOST_TARGET:-${DOTENV[DEPLOY_HOST]:-}}}"
SSH_KEY_FILE="$(expand_tilde "${CLI_SSH_KEY_FILE:-${CALLER_SSH_KEY_FILE:-${DOTENV[SSH_KEY_FILE]:-}}}")"
KNOWN_HOSTS_FILE="$(expand_tilde "${CLI_KNOWN_HOSTS_FILE:-${CALLER_KNOWN_HOSTS_FILE:-${DOTENV[KNOWN_HOSTS_FILE]:-}}}")"
PROJECT_ID="${CLI_PROJECT_ID:-${CALLER_PROJECT_ID:-${DOTENV[PROJECT_ID]:-}}}"
ZONE="${CLI_ZONE:-${CALLER_ZONE:-${DOTENV[ZONE]:-}}}"
MIG_NAME="${CLI_MIG_NAME:-${CALLER_MIG_NAME:-${DOTENV[MIG_NAME]:-}}}"
NAME_PREFIX="${CLI_NAME_PREFIX:-${CALLER_NAME_PREFIX:-${DOTENV[NAME_PREFIX]:-dev-gpu}}}"

REPO_SPEC="${CLI_REPO_SPEC:-${CALLER_REPO_SPEC:-${DOTENV[GITHUB_REPO]:-vitorecomp/personal-infra}}}"
GITHUB_ENV_NAME="${CLI_GITHUB_ENV:-$(env_or_dotenv GITHUB_ENV gpu)}"
RUNNER_TOKEN_VAL="${CLI_RUNNER_TOKEN:-${CALLER_RUNNER_TOKEN:-${DOTENV[RUNNER_TOKEN]:-}}}"
RUNNER_TOKEN_EXPIRES_VAL="${DOTENV[RUNNER_TOKEN_EXPIRES_AT]:-}"
RUNNER_PAT_VAL="${CLI_RUNNER_PAT:-${CALLER_RUNNER_PAT:-${DOTENV[RUNNER_PAT]:-}}}"
RUNNER_NAME="${CLI_RUNNER_NAME:-${CALLER_RUNNER_NAME:-${DOTENV[RUNNER_NAME]:-}}}"
RUNNER_LABELS="${CLI_RUNNER_LABELS:-${CALLER_RUNNER_LABELS:-${DOTENV[RUNNER_LABELS]:-}}}"
RUNNER_USER="${CLI_RUNNER_USER:-${CALLER_RUNNER_USER:-${DOTENV[RUNNER_USER]:-}}}"
RUNNER_DIR="${CLI_RUNNER_DIR:-${CALLER_RUNNER_DIR:-${DOTENV[RUNNER_DIR]:-/opt/actions-runner}}}"
WORK_DIR="${CLI_WORK_DIR:-${CALLER_WORK_DIR:-${DOTENV[RUNNER_WORK_DIR]:-_work}}}"
TRIGGER_DEPLOY="${CLI_TRIGGER_DEPLOY:-$(env_or_dotenv TRIGGER_DEPLOY false)}"

if [[ -z "$PROVIDER" && -z "$HOST_TARGET" ]] && ! $SYNC_GITHUB_ONLY; then
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

EFFECTIVE_TAG="${PROVIDER:-gcp}"
GPU_RUNNER_VAL="$(env_or_dotenv GPU_RUNNER "${EFFECTIVE_TAG}-gpu")"
GPU_RUNNER_LABELS_VAL="$(env_or_dotenv GPU_RUNNER_LABELS "")"
RUNNER_NAME="${RUNNER_NAME:-${EFFECTIVE_TAG}-gpu-runner}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,${GPU_RUNNER_VAL}}"

# Normalize GitHub owner/repo and full URL
REPO_PATH=""
REPO_URL=""
if [[ -n "$REPO_SPEC" ]]; then
  if [[ "$REPO_SPEC" =~ ^https?://github\.com/([^/]+/[^/]+)/?$ ]]; then
    REPO_PATH="${BASH_REMATCH[1]%.git}"
    REPO_URL="https://github.com/${REPO_PATH}"
  elif [[ "$REPO_SPEC" =~ ^https?:// ]]; then
    REPO_URL="${REPO_SPEC%/}"
  else
    REPO_PATH="${REPO_SPEC#/}"
    REPO_PATH="${REPO_PATH%/}"
    REPO_PATH="${REPO_PATH%.git}"
    REPO_URL="https://github.com/${REPO_PATH}"
  fi
fi

if [[ "$MODE" == "configure" && -z "$REPO_URL" ]]; then
  echo "[error] GITHUB_REPO (in development/.env or --repo=owner/repo) is required" >&2
  exit 1
fi

# Ensure `gh` authentication (uses GH_TOKEN from development/.env, active `gh auth login`,
# or falls back to GH_TOKEN / GITHUB_TOKEN in repo root `.env` if needed).
ensure_gh_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "[error] GitHub CLI ('gh') not found on PATH. Install with: sudo apt-get install -y gh" >&2
    exit 1
  fi
  if [[ -n "${DOTENV[GH_TOKEN]:-}" && -z "${GH_TOKEN:-}" ]]; then
    export GH_TOKEN="${DOTENV[GH_TOKEN]}"
  fi
  if gh auth status >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "$REPO_ROOT/.env" ]]; then
    local root_tok
    root_tok="$(python3 - "$REPO_ROOT/.env" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip() in ("GH_TOKEN", "GITHUB_TOKEN") and v.strip():
            print(v.strip().strip("'").strip('"'))
            break
PY
)"
    if [[ -n "$root_tok" ]]; then
      export GH_TOKEN="$root_tok"
      if gh auth status >/dev/null 2>&1; then
        return 0
      fi
    fi
  fi
  echo "[error] 'gh' is not authenticated. Run 'gh auth login' or set GH_TOKEN in $ENV_FILE." >&2
  exit 1
}

# Resolve stack secrets & variables from environment / `development/.env`
LITELLM_KEY_VAL="$(env_or_dotenv LITELLM_MASTER_KEY "__generate__")"
HF_TOKEN_VAL="$(env_or_dotenv HF_TOKEN "")"
ENABLE_TUNNELS_VAL="$(env_or_dotenv ENABLE_REVERSE_TUNNELS "false")"
TUNNEL_HOST_VAL="$(env_or_dotenv TUNNEL_SSH_HOST "")"
TUNNEL_PORT_VAL="$(env_or_dotenv TUNNEL_SSH_PORT "22")"
TUNNEL_USER_VAL="$(env_or_dotenv TUNNEL_SSH_USER "")"
TUNNEL_KEY_RAW="$(env_or_dotenv TUNNEL_SSH_KEY_FILE "__generate__")"
if [[ "$TUNNEL_KEY_RAW" == "__generate__" ]]; then
  TUNNEL_KEY_FILE_VAL="$HOME/.ssh/gpu_tunnel_ed25519"
else
  TUNNEL_KEY_FILE_VAL="$(expand_tilde "$TUNNEL_KEY_RAW")"
fi
TUNNEL_PRIV_KEY_INLINE="$(env_or_dotenv TUNNEL_SSH_PRIVATE_KEY "")"
TUNNEL_KH_RAW="$(env_or_dotenv TUNNEL_KNOWN_HOSTS "")"
TUNNEL_BIND_VAL="$(env_or_dotenv TUNNEL_BIND_ADDRESS "127.0.0.1")"
REMOTE_LITELLM_PORT_VAL="$(env_or_dotenv REMOTE_LITELLM_PORT "4000")"
REMOTE_HARNESS_PORT_VAL="$(env_or_dotenv REMOTE_HARNESS_PORT "3080")"

LITELLM_TUNNEL_HOST_VAL="$(env_or_dotenv LITELLM_TUNNEL_SSH_HOST "")"
LITELLM_TUNNEL_PORT_VAL="$(env_or_dotenv LITELLM_TUNNEL_SSH_PORT "")"
LITELLM_TUNNEL_USER_VAL="$(env_or_dotenv LITELLM_TUNNEL_SSH_USER "")"
HARNESS_TUNNEL_HOST_VAL="$(env_or_dotenv HARNESS_TUNNEL_SSH_HOST "")"
HARNESS_TUNNEL_PORT_VAL="$(env_or_dotenv HARNESS_TUNNEL_SSH_PORT "")"
HARNESS_TUNNEL_USER_VAL="$(env_or_dotenv HARNESS_TUNNEL_SSH_USER "")"

GPU_TARGET_MODE_VAL="$(env_or_dotenv GPU_TARGET_MODE "local")"
GPU_SSH_HOST_VAL="$(env_or_dotenv GPU_SSH_HOST "")"
GPU_SSH_KEY_FILE_VAL="$(expand_tilde "$(env_or_dotenv GPU_SSH_KEY_FILE "")")"
GPU_SSH_PRIV_KEY_INLINE="$(env_or_dotenv GPU_SSH_PRIVATE_KEY "")"
GPU_SSH_KH_VAL="$(env_or_dotenv GPU_SSH_KNOWN_HOSTS "")"

# Update a single key in `development/.env` in-place (preserving comments and mode 0600).
persist_key_in_dotenv() {
  local file="$1" key="$2" value="$3"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$key" "$value" <<'PY'
import os, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    lines = fh.readlines()
replaced = False
out = []
for line in lines:
    stripped = line.lstrip()
    if not stripped.startswith("#") and "=" in stripped:
        k = stripped.split("=", 1)[0].removeprefix("export ").strip()
        if k == key:
            out.append(f"{key}={val}\n")
            replaced = True
            continue
    out.append(line)
if not replaced:
    out.append(f"\n{key}={val}\n")
with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(out)
os.chmod(path, 0o600)
PY
}

# Returns 0 if a runner registration token is present, not `__generate__`, and valid for >=5 min.
runner_token_is_fresh() {
  local tok="$1" exp="$2"
  [[ -n "$tok" && "$tok" != "__generate__" ]] || return 1
  if [[ -n "$CLI_RUNNER_TOKEN" || -n "$CALLER_RUNNER_TOKEN" ]]; then
    return 0
  fi
  [[ -n "$exp" ]] || return 1
  python3 - "$exp" <<'PY' >/dev/null 2>&1
import datetime as dt, sys
raw = sys.argv[1].strip()
exp = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
now = dt.datetime.now(dt.timezone.utc)
sys.exit(0 if (exp - now).total_seconds() > 300 else 1)
PY
}

# Mints a fresh registration token via `gh api` (used only in SSH runner setup mode).
ensure_fresh_runner_registration_token() {
  [[ -z "$RUNNER_PAT_VAL" && -n "$REPO_PATH" ]] || return 0
  if runner_token_is_fresh "$RUNNER_TOKEN_VAL" "$RUNNER_TOKEN_EXPIRES_VAL"; then
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 0
  ensure_gh_auth
  echo "[gh] Minting fresh runner registration token for ${REPO_PATH}..."
  local resp
  resp="$(gh api -X POST "repos/${REPO_PATH}/actions/runners/registration-token")"
  RUNNER_TOKEN_VAL="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["token"])' "$resp")"
  RUNNER_TOKEN_EXPIRES_VAL="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("expires_at",""))' "$resp")"
}

sync_github_settings() {
  if [[ -z "$REPO_PATH" ]]; then
    echo "[error] Cannot sync GitHub variables/secrets without owner/repo path (got '$REPO_SPEC')." >&2
    exit 1
  fi

  ensure_gh_auth

  # Auto-generate local reverse-tunnel SSH keypair once when TUNNEL_SSH_KEY_FILE=__generate__ (or default path missing).
  if [[ "$TUNNEL_KEY_RAW" == "__generate__" || ( "$TUNNEL_KEY_FILE_VAL" == "$HOME/.ssh/gpu_tunnel_ed25519" && ! -f "$TUNNEL_KEY_FILE_VAL" ) ]]; then
    install -d -m 0700 "$HOME/.ssh"
    if [[ ! -f "$TUNNEL_KEY_FILE_VAL" ]]; then
      ssh-keygen -q -t ed25519 -N "" -C "gpu-dev-machine-reverse-tunnel" -f "$TUNNEL_KEY_FILE_VAL"
      chmod 600 "$TUNNEL_KEY_FILE_VAL"
      echo "[gh-sync] Generated reverse-tunnel SSH keypair at $TUNNEL_KEY_FILE_VAL (+ .pub)."
    fi
    if [[ -f "$ENV_FILE" ]]; then
      persist_key_in_dotenv "$ENV_FILE" "TUNNEL_SSH_KEY_FILE" "~/.ssh/gpu_tunnel_ed25519"
    fi
  fi

  if [[ "${ENABLE_TUNNELS_VAL,,}" == "true" ]]; then
    if [[ -z "$TUNNEL_HOST_VAL" || -z "$TUNNEL_USER_VAL" ]]; then
      echo "[error] ENABLE_REVERSE_TUNNELS=true requires TUNNEL_SSH_HOST and TUNNEL_SSH_USER in $ENV_FILE." >&2
      exit 1
    fi
    if [[ -z "$TUNNEL_KEY_FILE_VAL" && -z "$TUNNEL_PRIV_KEY_INLINE" ]]; then
      echo "[error] ENABLE_REVERSE_TUNNELS=true requires TUNNEL_SSH_KEY_FILE (path to private key) in $ENV_FILE." >&2
      exit 1
    fi
  fi
  if [[ -n "$TUNNEL_KEY_FILE_VAL" && ! -f "$TUNNEL_KEY_FILE_VAL" ]]; then
    echo "[error] TUNNEL_SSH_KEY_FILE does not exist: $TUNNEL_KEY_FILE_VAL" >&2
    exit 1
  fi
  if [[ -n "$GPU_SSH_KEY_FILE_VAL" && ! -f "$GPU_SSH_KEY_FILE_VAL" ]]; then
    echo "[error] GPU_SSH_KEY_FILE does not exist: $GPU_SSH_KEY_FILE_VAL" >&2
    exit 1
  fi

  # Auto-generate LITELLM_MASTER_KEY once if set to `__generate__` or empty.
  if [[ -z "$LITELLM_KEY_VAL" || "$LITELLM_KEY_VAL" == "__generate__" ]]; then
    LITELLM_KEY_VAL="sk-$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
    if [[ -f "$ENV_FILE" ]]; then
      persist_key_in_dotenv "$ENV_FILE" "LITELLM_MASTER_KEY" "$LITELLM_KEY_VAL"
      echo "[gh-sync] Generated LITELLM_MASTER_KEY and saved to $ENV_FILE (mode 0600)."
    else
      echo "[gh-sync] Generated LITELLM_MASTER_KEY for GitHub Environment '$GITHUB_ENV_NAME'."
    fi
  fi

  # Persist default runner identity keys in `development/.env` if empty.
  if [[ -f "$ENV_FILE" ]]; then
    [[ -z "${DOTENV[RUNNER_NAME]:-}" ]] && persist_key_in_dotenv "$ENV_FILE" "RUNNER_NAME" "$RUNNER_NAME"
    [[ -z "${DOTENV[RUNNER_LABELS]:-}" ]] && persist_key_in_dotenv "$ENV_FILE" "RUNNER_LABELS" "$RUNNER_LABELS"
    if [[ -z "$GPU_RUNNER_LABELS_VAL" ]]; then
      GPU_RUNNER_LABELS_VAL="[\"self-hosted\",\"linux\",\"x64\",\"${GPU_RUNNER_VAL}\"]"
      persist_key_in_dotenv "$ENV_FILE" "GPU_RUNNER_LABELS" "$GPU_RUNNER_LABELS_VAL"
    fi
  fi

  # Ensure the target GitHub Environment exists without clobbering existing protection rules.
  if ! gh api "repos/${REPO_PATH}/environments/${GITHUB_ENV_NAME}" >/dev/null 2>&1; then
    echo "[gh-sync] Creating GitHub Environment '${GITHUB_ENV_NAME}' on ${REPO_PATH}..."
    gh api -X PUT "repos/${REPO_PATH}/environments/${GITHUB_ENV_NAME}" >/dev/null
  fi

  echo "[gh-sync] Setting Repository Variable GPU_RUNNER=${GPU_RUNNER_VAL} on ${REPO_PATH}..."
  gh variable set GPU_RUNNER --repo "$REPO_PATH" --body "$GPU_RUNNER_VAL"
  if [[ -n "$GPU_RUNNER_LABELS_VAL" ]]; then
    echo "[gh-sync] Setting Repository Variable GPU_RUNNER_LABELS on ${REPO_PATH}..."
    gh variable set GPU_RUNNER_LABELS --repo "$REPO_PATH" --body "$GPU_RUNNER_LABELS_VAL"
  fi

  # Sync Secrets to `gpu` Environment (never print secret values)
  echo "[gh-sync] Uploading secret LITELLM_MASTER_KEY to environment '${GITHUB_ENV_NAME}'..."
  printf '%s' "$LITELLM_KEY_VAL" | gh secret set LITELLM_MASTER_KEY --repo "$REPO_PATH" --env "$GITHUB_ENV_NAME"

  if [[ -n "$HF_TOKEN_VAL" ]]; then
    echo "[gh-sync] Uploading secret HF_TOKEN to environment '${GITHUB_ENV_NAME}'..."
    printf '%s' "$HF_TOKEN_VAL" | gh secret set HF_TOKEN --repo "$REPO_PATH" --env "$GITHUB_ENV_NAME"
  fi

  if [[ -n "$TUNNEL_KEY_FILE_VAL" ]]; then
    echo "[gh-sync] Uploading secret TUNNEL_SSH_PRIVATE_KEY (from $TUNNEL_KEY_FILE_VAL) to environment '${GITHUB_ENV_NAME}'..."
    gh secret set TUNNEL_SSH_PRIVATE_KEY --repo "$REPO_PATH" --env "$GITHUB_ENV_NAME" < "$TUNNEL_KEY_FILE_VAL"
  elif [[ -n "$TUNNEL_PRIV_KEY_INLINE" ]]; then
    echo "[gh-sync] Uploading secret TUNNEL_SSH_PRIVATE_KEY to environment '${GITHUB_ENV_NAME}'..."
    printf '%s\n' "$TUNNEL_PRIV_KEY_INLINE" | gh secret set TUNNEL_SSH_PRIVATE_KEY --repo "$REPO_PATH" --env "$GITHUB_ENV_NAME"
  fi

  if [[ -n "$GPU_SSH_KEY_FILE_VAL" ]]; then
    echo "[gh-sync] Uploading secret GPU_SSH_PRIVATE_KEY (from $GPU_SSH_KEY_FILE_VAL) to environment '${GITHUB_ENV_NAME}'..."
    gh secret set GPU_SSH_PRIVATE_KEY --repo "$REPO_PATH" --env "$GITHUB_ENV_NAME" < "$GPU_SSH_KEY_FILE_VAL"
  elif [[ -n "$GPU_SSH_PRIV_KEY_INLINE" ]]; then
    echo "[gh-sync] Uploading secret GPU_SSH_PRIVATE_KEY to environment '${GITHUB_ENV_NAME}'..."
    printf '%s\n' "$GPU_SSH_PRIV_KEY_INLINE" | gh secret set GPU_SSH_PRIVATE_KEY --repo "$REPO_PATH" --env "$GITHUB_ENV_NAME"
  fi

  # If TUNNEL_KNOWN_HOSTS points to a local file on workstation, read its content.
  local effective_tunnel_kh="$TUNNEL_KH_RAW"
  local expanded_kh
  expanded_kh="$(expand_tilde "$TUNNEL_KH_RAW")"
  if [[ -n "$expanded_kh" && -f "$expanded_kh" ]]; then
    effective_tunnel_kh="$(cat "$expanded_kh")"
  fi

  local -a env_vars_to_set=(
    "ENABLE_REVERSE_TUNNELS=${ENABLE_TUNNELS_VAL}"
    "TUNNEL_SSH_PORT=${TUNNEL_PORT_VAL}"
    "TUNNEL_BIND_ADDRESS=${TUNNEL_BIND_VAL}"
    "REMOTE_LITELLM_PORT=${REMOTE_LITELLM_PORT_VAL}"
    "REMOTE_HARNESS_PORT=${REMOTE_HARNESS_PORT_VAL}"
    "GPU_TARGET_MODE=${GPU_TARGET_MODE_VAL}"
  )
  # Host names/IPs and host keys identify personal machines: store them as environment SECRETS so the
  # public repository's Actions logs mask them (plain variables are printed in each step's env block).
  local -a env_secrets_to_set=()
  [[ -n "$TUNNEL_HOST_VAL" ]] && env_secrets_to_set+=("TUNNEL_SSH_HOST=${TUNNEL_HOST_VAL}")
  [[ -n "$TUNNEL_USER_VAL" ]] && env_vars_to_set+=("TUNNEL_SSH_USER=${TUNNEL_USER_VAL}")
  [[ -n "$effective_tunnel_kh" ]] && env_secrets_to_set+=("TUNNEL_KNOWN_HOSTS=${effective_tunnel_kh}")
  [[ -n "$LITELLM_TUNNEL_HOST_VAL" ]] && env_secrets_to_set+=("LITELLM_TUNNEL_SSH_HOST=${LITELLM_TUNNEL_HOST_VAL}")
  [[ -n "$LITELLM_TUNNEL_PORT_VAL" ]] && env_vars_to_set+=("LITELLM_TUNNEL_SSH_PORT=${LITELLM_TUNNEL_PORT_VAL}")
  [[ -n "$LITELLM_TUNNEL_USER_VAL" ]] && env_vars_to_set+=("LITELLM_TUNNEL_SSH_USER=${LITELLM_TUNNEL_USER_VAL}")
  [[ -n "$HARNESS_TUNNEL_HOST_VAL" ]] && env_secrets_to_set+=("HARNESS_TUNNEL_SSH_HOST=${HARNESS_TUNNEL_HOST_VAL}")
  [[ -n "$HARNESS_TUNNEL_PORT_VAL" ]] && env_vars_to_set+=("HARNESS_TUNNEL_SSH_PORT=${HARNESS_TUNNEL_PORT_VAL}")
  [[ -n "$HARNESS_TUNNEL_USER_VAL" ]] && env_vars_to_set+=("HARNESS_TUNNEL_SSH_USER=${HARNESS_TUNNEL_USER_VAL}")
  [[ -n "$GPU_SSH_HOST_VAL" ]] && env_secrets_to_set+=("GPU_SSH_HOST=${GPU_SSH_HOST_VAL}")
  [[ -n "$GPU_SSH_KH_VAL" ]] && env_secrets_to_set+=("GPU_SSH_KNOWN_HOSTS=${GPU_SSH_KH_VAL}")

  local kv vname vbody
  local synced_var_names=()
  for kv in "${env_vars_to_set[@]}"; do
    vname="${kv%%=*}"
    vbody="${kv#*=}"
    gh variable set "$vname" --repo "$REPO_PATH" --env "$GITHUB_ENV_NAME" --body "$vbody"
    synced_var_names+=("$vname")
  done
  echo "[gh-sync] Synced '${GITHUB_ENV_NAME}' environment variables: ${synced_var_names[*]}"

  local synced_secret_names=()
  for kv in "${env_secrets_to_set[@]}"; do
    vname="${kv%%=*}"
    vbody="${kv#*=}"
    printf '%s\n' "$vbody" | gh secret set "$vname" --repo "$REPO_PATH" --env "$GITHUB_ENV_NAME"
    # Drop an older plain variable of the same name (it would show up unmasked in logs).
    gh variable delete "$vname" --repo "$REPO_PATH" --env "$GITHUB_ENV_NAME" >/dev/null 2>&1 || true
    synced_secret_names+=("$vname")
  done
  if (( ${#synced_secret_names[@]} )); then
    echo "[gh-sync] Synced '${GITHUB_ENV_NAME}' environment secrets (host identities): ${synced_secret_names[*]}"
  fi
}

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

resolve_gcp_mig_metadata() {
  local infra_dir="$DEV_ROOT/infra/gcp"
  GCP_PROJECT="${PROJECT_ID:-$(gcloud_config_value project)}"
  GCP_MIG_NAME="$MIG_NAME"
  GCP_MIG_ZONE="$ZONE"

  local -a tf_bin=()
  if command -v terraform >/dev/null 2>&1; then
    tf_bin=(terraform -chdir="$infra_dir")
  elif command -v mise >/dev/null 2>&1; then
    tf_bin=(mise exec --cd "$REPO_ROOT" -- terraform -chdir="$infra_dir")
  fi

  if [[ ${#tf_bin[@]} -gt 0 && -d "$infra_dir/.terraform" ]]; then
    local -a tf_env=()
    [[ -n "$GCP_PROJECT" ]] && tf_env=(env "TF_WORKSPACE=${GCP_PROJECT}")
    [[ -z "$GCP_PROJECT" ]] && GCP_PROJECT="$("${tf_env[@]}" "${tf_bin[@]}" output -raw project_id 2>/dev/null || true)"
    [[ -z "$GCP_MIG_NAME" ]] && GCP_MIG_NAME="$("${tf_env[@]}" "${tf_bin[@]}" output -raw mig_name 2>/dev/null || true)"
    [[ -z "$GCP_MIG_ZONE" ]] && GCP_MIG_ZONE="$("${tf_env[@]}" "${tf_bin[@]}" output -raw zone 2>/dev/null || "${tf_env[@]}" "${tf_bin[@]}" output -raw gpu_zone 2>/dev/null || true)"
  fi

  GCP_MIG_NAME="${GCP_MIG_NAME:-${NAME_PREFIX}-mig}"

  if [[ -z "$GCP_MIG_ZONE" && -n "$GCP_PROJECT" ]] && ! $DRY_RUN && command -v gcloud >/dev/null 2>&1; then
    GCP_MIG_ZONE="$(gcloud compute instance-groups managed list \
      --project="$GCP_PROJECT" \
      --filter="name=${GCP_MIG_NAME}" \
      --format="value(zone.basename())" 2>/dev/null | head -n 1 || true)"
  fi
}

gcp_zero_ssh_status() {
  if [[ -z "$REPO_PATH" ]]; then
    echo "[error] GITHUB_REPO (in development/.env or --repo=owner/repo) is required for --status." >&2
    exit 1
  fi
  ensure_gh_auth

  echo "[gh] Querying self-hosted runners on ${REPO_PATH} (filter: name='${RUNNER_NAME}' or label='${GPU_RUNNER_VAL}')..."
  local runners_json
  runners_json="$(gh api --paginate "repos/${REPO_PATH}/actions/runners")"

  python3 - "$RUNNER_NAME" "$GPU_RUNNER_VAL" "$REPO_PATH" 3<<<"$runners_json" <<'PY'
import json, os, sys

target_name, target_label, repo = sys.argv[1], sys.argv[2], sys.argv[3]
with os.fdopen(3, encoding="utf-8") as fh:
    raw = fh.read()
dec = json.JSONDecoder()
pos = 0
runners = []
while pos < len(raw):
    while pos < len(raw) and raw[pos].isspace():
        pos += 1
    if pos >= len(raw):
        break
    obj, end = dec.raw_decode(raw, pos)
    pos = end
    if isinstance(obj, dict) and isinstance(obj.get("runners"), list):
        runners.extend(obj["runners"])

def labels_of(r):
    return [lbl.get("name", "") for lbl in (r.get("labels") or []) if isinstance(lbl, dict)]

def matches(r):
    if r.get("name") == target_name:
        return True
    if target_label and target_label in labels_of(r):
        return True
    return False

matched = [r for r in runners if matches(r)]
others = [r for r in runners if not matches(r)]

def print_table(rows):
    headers = ("ID", "NAME", "STATUS", "BUSY", "LABELS")
    data = [
        (
            str(r.get("id", "")),
            str(r.get("name", "")),
            str(r.get("status", "")),
            "yes" if r.get("busy") else "no",
            ",".join(labels_of(r)),
        )
        for r in rows
    ]
    widths = [max(len(headers[i]), *(len(row[i]) for row in data)) for i in range(len(headers))]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths)
    print(fmt.format(*headers))
    print(fmt.format(*("-" * w for w in widths)))
    for row in data:
        print(fmt.format(*row))

if matched:
    print_table(matched)
else:
    print(f"[gh] No self-hosted runners matching name='{target_name}' or label='{target_label}' found on {repo}.")
    if others:
        print("[gh] Other runners registered on repository:")
        print_table(others)
PY

  if command -v gcloud >/dev/null 2>&1; then
    resolve_gcp_mig_metadata
    if [[ -n "$GCP_PROJECT" && -n "$GCP_MIG_NAME" && -n "$GCP_MIG_ZONE" ]]; then
      echo ""
      echo "[gcp] Managed instances for MIG '${GCP_MIG_NAME}' (project=${GCP_PROJECT}, zone=${GCP_MIG_ZONE}):"
      gcloud compute instance-groups managed list-instances "$GCP_MIG_NAME" \
        --zone="$GCP_MIG_ZONE" \
        --project="$GCP_PROJECT" || true
    elif [[ -n "$GCP_PROJECT" ]]; then
      echo ""
      echo "[gcp] No Stateful MIG named '${GCP_MIG_NAME}' found in project '${GCP_PROJECT}' (pass --zone or deploy via ./development/scripts/deploy.sh --provider=gcp)."
    fi
  fi
}

gcp_zero_ssh_remove() {
  if [[ -z "$REPO_PATH" ]]; then
    echo "[error] GITHUB_REPO (in development/.env or --repo=owner/repo) is required for --remove." >&2
    exit 1
  fi
  ensure_gh_auth

  echo "[gh] Looking up self-hosted runners on ${REPO_PATH} matching name='${RUNNER_NAME}' or label='${GPU_RUNNER_VAL}'..."
  local runners_json
  runners_json="$(gh api --paginate "repos/${REPO_PATH}/actions/runners")"

  local matched_lines
  matched_lines="$(python3 - "$RUNNER_NAME" "$GPU_RUNNER_VAL" 3<<<"$runners_json" <<'PY'
import json, os, sys

target_name, target_label = sys.argv[1], sys.argv[2]
with os.fdopen(3, encoding="utf-8") as fh:
    raw = fh.read()
dec = json.JSONDecoder()
pos = 0
runners = []
while pos < len(raw):
    while pos < len(raw) and raw[pos].isspace():
        pos += 1
    if pos >= len(raw):
        break
    obj, end = dec.raw_decode(raw, pos)
    pos = end
    if isinstance(obj, dict) and isinstance(obj.get("runners"), list):
        runners.extend(obj["runners"])

for r in runners:
    rname = str(r.get("name", ""))
    lbls = [lbl.get("name", "") for lbl in (r.get("labels") or []) if isinstance(lbl, dict)]
    if rname == target_name or (target_label and target_label in lbls):
        rid = str(r.get("id", ""))
        rstatus = str(r.get("status", ""))
        rbusy = "true" if r.get("busy") else "false"
        print(f"{rid}\t{rname}\t{rstatus}\t{rbusy}")
PY
)"

  if [[ -z "$matched_lines" ]]; then
    echo "[gh] No matching self-hosted runners found on ${REPO_PATH}; nothing to remove."
    return 0
  fi

  local rid rname rstatus rbusy failed=0
  while IFS=$'\t' read -r rid rname rstatus rbusy; do
    [[ -z "$rid" ]] && continue
    if [[ "$rbusy" == "true" ]]; then
      echo "[warn] Runner id=${rid} name='${rname}' is currently busy; skipping deletion (wait for job completion or cancel it first)." >&2
      failed=1
      continue
    fi
    if gh api -X DELETE "repos/${REPO_PATH}/actions/runners/${rid}" >/dev/null; then
      echo "[gh] Removed runner registration: id=${rid} name='${rname}' (status was ${rstatus})."
    else
      echo "[error] Failed to delete runner id=${rid} name='${rname}' via GitHub API." >&2
      failed=1
    fi
  done <<< "$matched_lines"

  echo "[gcp] Note: To prevent the Stateful MIG VM from re-registering on reboot, destroy or scale down the MIG with './development/scripts/deploy.sh --provider=gcp --destroy'."
  return "$failed"
}

# GCP without explicit --host is 100% SSH-free (MIG self-registers via Secret Manager).
GCP_ZERO_SSH=false
TRANSPORT="ssh"
GCP_PROJECT=""
GCP_MIG_NAME=""
GCP_MIG_ZONE=""

if [[ "$PROVIDER" == "gcp" && -z "$HOST_TARGET" ]]; then
  GCP_ZERO_SSH=true
  TRANSPORT="github-api"
  if [[ "$MODE" == "status" ]] && $DRY_RUN; then
    resolve_gcp_mig_metadata
  fi
elif ! $SYNC_GITHUB_ONLY; then
  if [[ -n "$PROVIDER" ]]; then
    INFRA_DIR="$DEV_ROOT/infra/$PROVIDER"
    [[ -z "$SSH_KEY_FILE" && -f "$INFRA_DIR/ssh-key" ]] && SSH_KEY_FILE="$INFRA_DIR/ssh-key"
    [[ -z "$KNOWN_HOSTS_FILE" && -f "$INFRA_DIR/known_hosts" ]] && KNOWN_HOSTS_FILE="$INFRA_DIR/known_hosts"

    if [[ -z "$HOST_TARGET" && -d "$INFRA_DIR/.terraform" ]] && command -v terraform >/dev/null 2>&1; then
      host_ip="$(terraform -chdir="$INFRA_DIR" output -raw external_ip 2>/dev/null || terraform -chdir="$INFRA_DIR" output -raw controller_external_ip 2>/dev/null || true)"
      ssh_user="$(terraform -chdir="$INFRA_DIR" output -raw ssh_username 2>/dev/null || true)"
      [[ -n "$host_ip" && -n "$ssh_user" ]] && HOST_TARGET="${ssh_user}@${host_ip}"
    fi
  fi

  if [[ -z "$HOST_TARGET" ]]; then
    if $DRY_RUN; then
      HOST_TARGET="<deployed-${EFFECTIVE_TAG}-host-user@ip>"
    else
      echo "[error] Could not resolve target SSH host for provider '${PROVIDER:-custom}'. Pass --host=USER@IP." >&2
      exit 1
    fi
  fi
fi

RUNNER_USER="${RUNNER_USER:-github-runner}"

SSH_ARGS=()
if ! $SYNC_GITHUB_ONLY && ! $GCP_ZERO_SSH; then
  SSH_ARGS=(-o ConnectTimeout=15 -o ServerAliveInterval=30)
  [[ -n "$SSH_KEY_FILE" ]] && SSH_ARGS+=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes)
  [[ -n "$KNOWN_HOSTS_FILE" ]] && SSH_ARGS+=(-o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -o StrictHostKeyChecking=yes)
fi

if $DRY_RUN; then
  echo "[dry-run] Provider / Mode:      ${PROVIDER:-custom} / $MODE (sync_github=$SYNC_GITHUB, sync_github_only=$SYNC_GITHUB_ONLY, gcp_zero_ssh=$GCP_ZERO_SSH)"
  echo "[dry-run] Env File:             $ENV_FILE ($( [[ -f "$ENV_FILE" ]] && echo "loaded" || echo "not present; using defaults/CLI" ))"
  echo "[dry-run] GitHub Repo / Env:    ${REPO_PATH:-$REPO_URL} / $GITHUB_ENV_NAME"
  if $SYNC_GITHUB && [[ "$MODE" == "configure" ]]; then
    echo "[dry-run] GitHub CLI Sync Steps:"
    echo "[dry-run]   gh variable set GPU_RUNNER --repo ${REPO_PATH:-<repo>} --body $GPU_RUNNER_VAL"
    [[ -n "$GPU_RUNNER_LABELS_VAL" ]] && echo "[dry-run]   gh variable set GPU_RUNNER_LABELS --repo ${REPO_PATH:-<repo>} --body '$GPU_RUNNER_LABELS_VAL'"
    echo "[dry-run]   gh secret set LITELLM_MASTER_KEY --repo ${REPO_PATH:-<repo>} --env $GITHUB_ENV_NAME (<redacted / auto-generated if __generate__>)"
    [[ -n "$HF_TOKEN_VAL" ]] && echo "[dry-run]   gh secret set HF_TOKEN --repo ${REPO_PATH:-<repo>} --env $GITHUB_ENV_NAME (<redacted>)"
    [[ -n "$TUNNEL_KEY_FILE_VAL" || -n "$TUNNEL_PRIV_KEY_INLINE" ]] && echo "[dry-run]   gh secret set TUNNEL_SSH_PRIVATE_KEY --repo ${REPO_PATH:-<repo>} --env $GITHUB_ENV_NAME (<redacted>)"
    [[ -n "$GPU_SSH_KEY_FILE_VAL" || -n "$GPU_SSH_PRIV_KEY_INLINE" ]] && echo "[dry-run]   gh secret set GPU_SSH_PRIVATE_KEY --repo ${REPO_PATH:-<repo>} --env $GITHUB_ENV_NAME (<redacted>)"
    echo "[dry-run]   gh variable set ENABLE_REVERSE_TUNNELS, TUNNEL_SSH_PORT/USER, TUNNEL_BIND_ADDRESS, REMOTE_*, GPU_TARGET_MODE=${GPU_TARGET_MODE_VAL} --repo ${REPO_PATH:-<repo>} --env $GITHUB_ENV_NAME"
    echo "[dry-run]   gh secret set TUNNEL_SSH_HOST, TUNNEL_KNOWN_HOSTS (and per-tunnel/GPU_SSH hosts when set) --repo ${REPO_PATH:-<repo>} --env $GITHUB_ENV_NAME (<redacted>)"
  fi
  if $GCP_ZERO_SSH; then
    echo "[dry-run] Transport:            none (GCP zero-SSH mode; Stateful MIG self-registers via Secret Manager)"
    case "$MODE" in
      configure)
        echo "[dry-run] GCP Runner Setup:     Self-registered automatically on boot by './development/scripts/deploy.sh --provider=gcp' (runner=${RUNNER_NAME}, labels=${RUNNER_LABELS})"
        ;;
      status)
        echo "[dry-run] Status Commands (zero SSH):"
        echo "[dry-run]   gh api --paginate repos/${REPO_PATH:-<repo>}/actions/runners  # filter: name=${RUNNER_NAME} or label=${GPU_RUNNER_VAL}"
        echo "[dry-run]   gcloud compute instance-groups managed list-instances ${GCP_MIG_NAME:-${NAME_PREFIX}-mig} --zone=${GCP_MIG_ZONE:-<mig-zone>} --project=${GCP_PROJECT:-<gcloud-active-project>}"
        ;;
      remove)
        echo "[dry-run] Remove Commands (zero SSH):"
        echo "[dry-run]   gh api --paginate repos/${REPO_PATH:-<repo>}/actions/runners  # find matching name=${RUNNER_NAME} or label=${GPU_RUNNER_VAL}"
        echo "[dry-run]   gh api -X DELETE repos/${REPO_PATH:-<repo>}/actions/runners/<runner_id>"
        ;;
    esac
  elif ! $SYNC_GITHUB_ONLY; then
    echo "[dry-run] SSH Transport:        ssh $HOST_TARGET"
    echo "[dry-run] Runner User / Dir:    $RUNNER_USER / $RUNNER_DIR"
    if [[ "$MODE" == "configure" ]]; then
      echo "[dry-run] Runner Name / Labels: $RUNNER_NAME / $RUNNER_LABELS"
      if [[ -n "$RUNNER_PAT_VAL" ]]; then
        echo "[dry-run] Runner Auth:          --pat (<redacted>)"
      elif [[ -n "$RUNNER_TOKEN_VAL" && "$RUNNER_TOKEN_VAL" != "__generate__" ]]; then
        echo "[dry-run] Runner Auth:          --token (<redacted>)"
      else
        echo "[dry-run] Runner Auth:          gh api -X POST repos/${REPO_PATH:-<repo>}/actions/runners/registration-token -q .token"
      fi
      echo "[dry-run] Remote SSH Steps:"
      echo "[dry-run]   1. Ensure user '$RUNNER_USER', '$RUNNER_DIR', OS/.NET runner packages, and actions-runner binary exist"
      echo "[dry-run]   2. Stop/uninstall any prior systemd runner unit in '$RUNNER_DIR' if re-registering"
      echo "[dry-run]   3. Run 'sudo -u $RUNNER_USER $RUNNER_DIR/config.sh --unattended --url $REPO_URL --name $RUNNER_NAME --labels $RUNNER_LABELS --work $WORK_DIR --replace'"
      echo "[dry-run]   4. Run 'sudo ./svc.sh install $RUNNER_USER && sudo ./svc.sh start && sudo ./svc.sh status'"
    elif [[ "$MODE" == "remove" ]]; then
      echo "[dry-run] Remote SSH Steps:"
      echo "[dry-run]   1. Auto-mint remove token via 'gh api -X POST repos/${REPO_PATH:-<repo>}/actions/runners/remove-token' (if --token/--pat omitted)"
      echo "[dry-run]   2. Stop & uninstall systemd runner service in '$RUNNER_DIR' and run './config.sh remove'"
    else
      echo "[dry-run] Remote SSH Steps:"
      echo "[dry-run]   Check '$RUNNER_DIR/svc.sh status'"
    fi
  fi
  if [[ "${TRIGGER_DEPLOY,,}" == "true" && "$MODE" == "configure" ]]; then
    echo "[dry-run] Post-Setup Trigger:   gh workflow run deploy-gpu-machine.yml --repo ${REPO_PATH:-<repo>}"
  fi
  exit 0
fi

# ------------------------------------------------------------------------------
# GCP Zero-SSH Path (default configure / --status / --remove)
# ------------------------------------------------------------------------------
if $GCP_ZERO_SSH; then
  case "$MODE" in
    status)
      gcp_zero_ssh_status
      exit 0
      ;;
    remove)
      gcp_zero_ssh_remove
      exit $?
      ;;
    configure)
      if $SYNC_GITHUB; then
        sync_github_settings
      fi
      echo ""
      echo "[gcp] GitHub variables & '${GITHUB_ENV_NAME}' environment secrets synced for ${REPO_PATH} (GPU_TARGET_MODE=${GPU_TARGET_MODE_VAL})."
      echo "[gcp] Zero-SSH mode: the GCP Stateful MIG GPU VM self-registers runner '${RUNNER_NAME}' (${RUNNER_LABELS}) automatically on boot via Secret Manager."
      echo "[gcp] Provision / update the MIG: ./development/scripts/deploy.sh --provider=gcp"
      echo "[gcp] Check runner & MIG status:  ./development/scripts/setup.sh --provider=gcp --status"
      if [[ "${TRIGGER_DEPLOY,,}" == "true" && -n "$REPO_PATH" ]]; then
        ensure_gh_auth
        echo "[gh] Triggering workflow deploy-gpu-machine.yml on ${REPO_PATH}..."
        gh workflow run deploy-gpu-machine.yml --repo "$REPO_PATH"
      fi
      exit 0
      ;;
  esac
fi

# ------------------------------------------------------------------------------
# SSH Path (azure / on-prem / explicit --host=USER@IP)
# ------------------------------------------------------------------------------
if $SYNC_GITHUB && [[ "$MODE" == "configure" ]]; then
  sync_github_settings
fi

if $SYNC_GITHUB_ONLY; then
  if [[ "${TRIGGER_DEPLOY,,}" == "true" && -n "$REPO_PATH" ]]; then
    ensure_gh_auth
    echo "[gh-sync] Triggering deploy-gpu-machine.yml on ${REPO_PATH}..."
    gh workflow run deploy-gpu-machine.yml --repo "$REPO_PATH"
  fi
  exit 0
fi

run_remote_command() {
  local cmd="$1"
  ssh "${SSH_ARGS[@]}" "$HOST_TARGET" "$cmd"
}

run_remote_stdin_script() {
  echo "[ssh] Connecting via: ssh ${SSH_ARGS[*]} $HOST_TARGET 'bash -s'"
  ssh "${SSH_ARGS[@]}" "$HOST_TARGET" "bash -s"
}

if [[ "$MODE" == "status" ]]; then
  run_remote_command "cd '$RUNNER_DIR' && sudo ./svc.sh status"
  exit 0
fi

# Auto-mint registration / removal token via `gh api` when neither --token nor --pat was supplied.
if [[ "$MODE" == "remove" ]]; then
  if [[ -z "$CLI_RUNNER_TOKEN" && -z "$CALLER_RUNNER_TOKEN" && -z "$RUNNER_PAT_VAL" && -n "$REPO_PATH" ]] && command -v gh >/dev/null 2>&1; then
    ensure_gh_auth
    echo "[gh] Minting runner removal token for ${REPO_PATH}..."
    RUNNER_TOKEN_VAL="$(gh api -X POST "repos/${REPO_PATH}/actions/runners/remove-token" -q .token)"
  fi
else
  ensure_fresh_runner_registration_token
fi

if [[ ( -z "$RUNNER_TOKEN_VAL" || "$RUNNER_TOKEN_VAL" == "__generate__" ) && -z "$RUNNER_PAT_VAL" ]]; then
  if [[ -t 0 ]]; then
    read -rsp "Enter GitHub runner token: " RUNNER_TOKEN_VAL
    echo ""
  fi
  if [[ -z "$RUNNER_TOKEN_VAL" && -z "$RUNNER_PAT_VAL" ]]; then
    echo "[error] Could not obtain runner token via 'gh api'; authenticate 'gh auth login' or pass --token / --pat." >&2
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
echo "[host] Connected to $(hostname) as $(whoami)."

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
echo "[host] Ensuring runner dependencies and directory ($REMOTE_RUNNER_DIR)..."
for _ in $(seq 1 24); do
  if ! sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

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

echo "[host] Registering runner '$REMOTE_RUNNER_NAME' ($REMOTE_RUNNER_LABELS) against $REMOTE_REPO_URL..."
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

if [[ "${TRIGGER_DEPLOY,,}" == "true" && -n "$REPO_PATH" ]]; then
  ensure_gh_auth
  echo "[gh] Triggering workflow deploy-gpu-machine.yml on ${REPO_PATH}..."
  gh workflow run deploy-gpu-machine.yml --repo "$REPO_PATH"
fi
