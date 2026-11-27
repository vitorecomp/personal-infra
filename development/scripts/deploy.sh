#!/usr/bin/env bash
# Unified entrypoint to provision GPU development machines via Terraform.
#
# Routes `--provider=<gcp|azure|on-prem>` to `development/infra/<provider>` and
# runs Terraform using the currently logged-in CLI credentials (and active GCP
# project from `gcloud config` when `--provider=gcp`).
#
# On GCP, provisioning is 100% SSH-free: Terraform creates a single-VM Stateful
# Zonal Managed Instance Group (`<name_prefix>-mig`, `target_size = 1`) and a
# Secret Manager bootstrap secret (`<name_prefix>-runner-bootstrap`). On boot,
# the GPU VM mounts its persistent 3 TB Hyperdisk at `/mnt/data`, installs
# NVIDIA drivers + Podman, self-registers as a GitHub Actions runner, and
# auto-resumes any previously deployed Podman stack across Spot recreations.
#
# Usage:
#   ./development/scripts/deploy.sh --provider=gcp --dry-run
#   ./development/scripts/deploy.sh --provider=gcp
#   ./development/scripts/deploy.sh --provider=gcp --no-spot --use-default-vpc
#   ./development/scripts/deploy.sh --provider=gcp --cycle-regions --loop=5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEV_ROOT/.." && pwd)"

ENV_FILE="$DEV_ROOT/.env"
EXPLICIT_ENV_FILE=false

PROVIDER="${PROVIDER:-}"
ACTION="apply"
DRY_RUN=false
AUTH_MODE="${AUTH_MODE:-auto}" # auto | gcloud | adc
AUTO_APPROVE="${AUTO_APPROVE:-true}"

# Optional overrides (CLI > caller env > development/.env > terraform.tfvars > defaults)
PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-}"
ZONE="${ZONE:-}"
CLI_REGION=""
CLI_ZONE=""
REGIONS_LIST="${REGIONS:-}"
CYCLE_REGIONS="${CYCLE_REGIONS:-false}"
FORCE_MOVE="${FORCE_MOVE:-false}"
STAGE_ON_EXHAUSTION="${STAGE_ON_EXHAUSTION:-true}"
EXPLICIT_STAGE_FLAG=false
LOOP_MINUTES="${LOOP_MINUTES:-0}"
MACHINE_TYPE="${MACHINE_TYPE:-}"
NAME_PREFIX="${NAME_PREFIX:-}"
USE_SPOT="${USE_SPOT:-}"
USE_DEFAULT_VPC="${USE_DEFAULT_VPC:-}"
DEFAULT_VPC_NAME="${DEFAULT_VPC_NAME:-}"
ENABLE_INGRESS_FIREWALLS="${ENABLE_INGRESS_FIREWALLS:-}"
SSH_PROXY_CIDRS="${SSH_PROXY_CIDRS:-}"
GCP_SSH_HOSTNAME_TEMPLATE="${GCP_SSH_HOSTNAME_TEMPLATE:-}"
GCP_SSH_TEMPLATE_ACCOUNT_SUFFIX="${GCP_SSH_TEMPLATE_ACCOUNT_SUFFIX:-}"

# Runner bootstrap overrides (stored in GCP Secret Manager; tokens/PATs pass via TF_VAR_*)
GITHUB_REPO="${GITHUB_REPO:-}"
GPU_RUNNER="${GPU_RUNNER:-}"
RUNNER_NAME="${RUNNER_NAME:-}"
RUNNER_LABELS="${RUNNER_LABELS:-}"
RUNNER_USER="${RUNNER_USER:-}"
RUNNER_PAT="${RUNNER_PAT:-}"
GH_TOKEN_CALLER="${GH_TOKEN:-}"

ORIG_ARGS=("$@")

usage() {
  cat <<'EOF'
Usage: ./development/scripts/deploy.sh --provider=<gcp|azure|on-prem> [options]

Provision or manage GPU development machine infrastructure via Terraform.
On GCP, deploys a self-registering single-VM Stateful Zonal Managed Instance
Group (<prefix>-mig) backed by a persistent 3 TB Hyperdisk and GCP Secret
Manager (<prefix>-runner-bootstrap), with zero inbound SSH required.

Required:
  --provider=PROVIDER           Target infrastructure provider: gcp, azure, or on-prem

Actions:
  --apply                       Initialize and apply Terraform (default)
  --plan                        Initialize and run terraform plan only
  --validate                    Initialize (-backend=false) and validate Terraform
  --destroy                     Destroy Terraform-managed infrastructure
  --loop=MINUTES                Retry apply every MINUTES minutes until deployment succeeds (e.g. --loop=5)
  --dry-run                     Print resolved settings, API calls, and Terraform commands without executing

GCP / Terraform Options:
  --env-file=PATH               Path to .env file (default: development/.env)
  --project=PROJECT_ID          Override active gcloud project (defaults to `gcloud config get-value project`)
  --adc                         Force Application Default Credentials (automatic for @google.com CBA accounts)
  --gcloud-token                Force GOOGLE_OAUTH_ACCESS_TOKEN from `gcloud auth print-access-token`
  --region=REGION               Target region (default: REGION in .env, terraform.tfvars, or europe-west4)
  --zone=ZONE                   Target zone (default: ZONE in .env, terraform.tfvars, or candidate GPU zones)
  --regions=R1,R2,...           Comma-separated regions to cycle through for GPU capacity
  --cycle-regions               Cycle through all GPU-capable regions until capacity is found
  --machine-type=TYPE           GPU VM machine type override (default: g4-standard-192)
  --name-prefix=PREFIX          Resource name prefix override (default: dev-gpu)
  --spot                        Provision the GPU VM as a Spot VM auto-healed by the MIG (default)
  --no-spot, --standard         Provision the GPU VM as a Standard on-demand VM (sets use_spot=false)
  --use-default-vpc             Attach the MIG to the existing 'default' VPC instead of creating a custom VPC
  --no-use-default-vpc          Create and use a dedicated custom VPC (default; alias: --custom-vpc)
  --default-vpc-name=NAME       Existing VPC name when --use-default-vpc is set (default: default)
  --ssh-proxy-cidrs=C1,C2,...   Proxy CIDRs allowed on TCP 22 for optional debugging (default: 35.235.240.0/20)
  --ssh-hostname-template=TPL   Optional SSH relay hostname template ({instance}, {zone}, {project})
  --force-move                  Allow moving to another region/zone even if a MIG exists in state
  --no-stage-terminated         Destroy pending MIG and exit 1 on stockout (default when --loop is set)
  --stage-terminated            Keep MIG active on final candidate on stockout (even when --loop is set)
  --auto-approve                Pass -auto-approve to terraform apply/destroy (default)
  --no-auto-approve             Require interactive approval on terraform apply/destroy

Self-Registering Runner Options (stored in GCP Secret Manager):
  --repo=OWNER/REPO             GitHub repository to register against (default: GITHUB_REPO in .env)
  --runner-name=NAME            Self-hosted runner name (default: RUNNER_NAME in .env, else <provider>-gpu-runner)
  --runner-labels=L1,L2,...     Comma-separated runner labels (default: self-hosted,linux,x64,<GPU_RUNNER>)
  --runner-user=USER            Non-root OS user for the runner service (default: github-runner)

Other:
  -h, --help                    Show this help message and exit

Examples:
  # Preview a Spot GPU MIG deployment on GCP (safe, read-only):
  ./development/scripts/deploy.sh --provider=gcp --dry-run

  # Provision a Standard (on-demand) GPU MIG on the existing 'default' VPC:
  ./development/scripts/deploy.sh --provider=gcp --no-spot --use-default-vpc

  # Cycle across all GPU-capable regions every 5 minutes until Spot capacity opens:
  ./development/scripts/deploy.sh --provider=gcp --spot --cycle-regions --loop=5

  # Inspect planned Terraform changes or tear down the MIG:
  ./development/scripts/deploy.sh --provider=gcp --plan
  ./development/scripts/deploy.sh --provider=gcp --destroy
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
    --env-file=*) ENV_FILE="${1#*=}"; EXPLICIT_ENV_FILE=true; shift ;;
    --env-file) require_arg "$1" "${2:-}"; ENV_FILE="$2"; EXPLICIT_ENV_FILE=true; shift 2 ;;
    --apply) ACTION="apply"; shift ;;
    --plan) ACTION="plan"; shift ;;
    --validate) ACTION="validate"; shift ;;
    --destroy) ACTION="destroy"; shift ;;
    --loop=*|loop=*) LOOP_MINUTES="${1#*=}"; shift ;;
    --loop)
      if [[ $# -ge 2 && "${2:-}" =~ ^[0-9]+$ ]]; then
        LOOP_MINUTES="$2"; shift 2
      else
        LOOP_MINUTES="5"; shift
      fi
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    --adc) AUTH_MODE="adc"; shift ;;
    --gcloud-token) AUTH_MODE="gcloud"; shift ;;
    --project=*) PROJECT_ID="${1#*=}"; shift ;;
    --project) require_arg "$1" "${2:-}"; PROJECT_ID="$2"; shift 2 ;;
    --region=*) REGION="${1#*=}"; CLI_REGION="${1#*=}"; shift ;;
    --region) require_arg "$1" "${2:-}"; REGION="$2"; CLI_REGION="$2"; shift 2 ;;
    --zone=*) ZONE="${1#*=}"; CLI_ZONE="${1#*=}"; shift ;;
    --zone) require_arg "$1" "${2:-}"; ZONE="$2"; CLI_ZONE="$2"; shift 2 ;;
    --regions=*) REGIONS_LIST="${1#*=}"; shift ;;
    --regions) require_arg "$1" "${2:-}"; REGIONS_LIST="$2"; shift 2 ;;
    --cycle-regions) CYCLE_REGIONS="true"; shift ;;
    --machine-type=*) MACHINE_TYPE="${1#*=}"; shift ;;
    --machine-type) require_arg "$1" "${2:-}"; MACHINE_TYPE="$2"; shift 2 ;;
    --name-prefix=*) NAME_PREFIX="${1#*=}"; shift ;;
    --name-prefix) require_arg "$1" "${2:-}"; NAME_PREFIX="$2"; shift 2 ;;
    --spot) USE_SPOT="true"; shift ;;
    --no-spot|--standard) USE_SPOT="false"; shift ;;
    --use-default-vpc) USE_DEFAULT_VPC="true"; shift ;;
    --no-use-default-vpc|--custom-vpc) USE_DEFAULT_VPC="false"; shift ;;
    --default-vpc-name=*) DEFAULT_VPC_NAME="${1#*=}"; USE_DEFAULT_VPC="${USE_DEFAULT_VPC:-true}"; shift ;;
    --default-vpc-name) require_arg "$1" "${2:-}"; DEFAULT_VPC_NAME="$2"; USE_DEFAULT_VPC="${USE_DEFAULT_VPC:-true}"; shift 2 ;;
    --ssh-proxy-cidrs=*) SSH_PROXY_CIDRS="${1#*=}"; shift ;;
    --ssh-proxy-cidrs) require_arg "$1" "${2:-}"; SSH_PROXY_CIDRS="$2"; shift 2 ;;
    --ssh-hostname-template=*) GCP_SSH_HOSTNAME_TEMPLATE="${1#*=}"; shift ;;
    --ssh-hostname-template) require_arg "$1" "${2:-}"; GCP_SSH_HOSTNAME_TEMPLATE="$2"; shift 2 ;;
    --repo=*) GITHUB_REPO="${1#*=}"; shift ;;
    --repo) require_arg "$1" "${2:-}"; GITHUB_REPO="$2"; shift 2 ;;
    --runner-name=*) RUNNER_NAME="${1#*=}"; shift ;;
    --runner-name) require_arg "$1" "${2:-}"; RUNNER_NAME="$2"; shift 2 ;;
    --runner-labels=*) RUNNER_LABELS="${1#*=}"; shift ;;
    --runner-labels) require_arg "$1" "${2:-}"; RUNNER_LABELS="$2"; shift 2 ;;
    --runner-user=*) RUNNER_USER="${1#*=}"; shift ;;
    --runner-user) require_arg "$1" "${2:-}"; RUNNER_USER="$2"; shift 2 ;;
    --force-move) FORCE_MOVE="true"; shift ;;
    --no-stage-terminated) STAGE_ON_EXHAUSTION="false"; EXPLICIT_STAGE_FLAG=true; shift ;;
    --stage-terminated) STAGE_ON_EXHAUSTION="true"; EXPLICIT_STAGE_FLAG=true; shift ;;
    --auto-approve) AUTO_APPROVE="true"; shift ;;
    --no-auto-approve) AUTO_APPROVE="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[error] Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$PROVIDER" ]]; then
  echo "[error] --provider is required (expected: gcp, azure, or on-prem)" >&2
  usage >&2
  exit 1
fi

if $EXPLICIT_ENV_FILE && [[ ! -f "$ENV_FILE" ]]; then
  echo "[error] Specified --env-file does not exist: $ENV_FILE" >&2
  exit 1
fi

if ! [[ "$LOOP_MINUTES" =~ ^[0-9]+$ ]]; then
  echo "[error] --loop expects a non-negative integer number of minutes (got: '$LOOP_MINUTES')" >&2
  exit 1
fi

# When looping until live capacity is obtained, default to not stopping early on a
# pending/exhausted MIG unless --stage-terminated was explicitly requested.
if (( LOOP_MINUTES > 0 )) && ! $EXPLICIT_STAGE_FLAG; then
  STAGE_ON_EXHAUSTION="false"
fi

# Outer retry loop: re-invokes this script with LOOP_MINUTES=0 so `set -e`, temp-file
# traps, credential refresh, registration token minting, and state inspection run
# cleanly on every attempt.
if (( LOOP_MINUTES > 0 )) && [[ "$ACTION" == "apply" ]] && ! $DRY_RUN; then
  CHILD_ARGS=()
  skip_next=false
  for ((i = 0; i < ${#ORIG_ARGS[@]}; i++)); do
    if $skip_next; then
      skip_next=false
      continue
    fi
    arg="${ORIG_ARGS[$i]}"
    case "$arg" in
      --loop=*|loop=*) continue ;;
      --loop)
        next_arg="${ORIG_ARGS[$((i + 1))]:-}"
        [[ "$next_arg" =~ ^[0-9]+$ ]] && skip_next=true
        continue
        ;;
      *) CHILD_ARGS+=("$arg") ;;
    esac
  done
  if ! $EXPLICIT_STAGE_FLAG; then
    CHILD_ARGS+=(--no-stage-terminated)
  fi

  trap 'echo ""; echo "[$(date "+%F %T")] [loop] Interrupted; stopping retry loop."; exit 130' INT TERM
  attempt=0
  sleep_sec=$(( LOOP_MINUTES * 60 ))
  while true; do
    attempt=$(( attempt + 1 ))
    echo "[$(date '+%F %T')] [loop] Attempt #${attempt} (retrying every ${LOOP_MINUTES}m until success; Ctrl-C to stop)..."
    set +e
    LOOP_MINUTES=0 "${BASH_SOURCE[0]}" "${CHILD_ARGS[@]}"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      echo "[$(date '+%F %T')] [loop] Deployment succeeded on attempt #${attempt}!"
      exit 0
    fi
    if [[ $rc -eq 130 || $rc -eq 143 ]]; then
      exit "$rc"
    fi
    echo "[$(date '+%F %T')] [loop] Attempt #${attempt} exited with code ${rc}; sleeping ${LOOP_MINUTES} minute(s) (${sleep_sec}s) before retry..."
    sleep "$sleep_sec"
  done
fi

case "$PROVIDER" in
  gcp) PROVIDER="gcp" ;;
  azure) PROVIDER="azure" ;;
  on-prem|on_prem|onprem) PROVIDER="on-prem" ;;
  *)
    echo "[error] Unsupported provider '$PROVIDER' (expected: gcp, azure, or on-prem)" >&2
    exit 1
    ;;
esac

INFRA_DIR="$DEV_ROOT/infra/$PROVIDER"
if [[ ! -d "$INFRA_DIR" ]]; then
  echo "[error] Infrastructure directory does not exist: $INFRA_DIR" >&2
  exit 1
fi

# Prefer terraform on PATH, falling back to mise if installed.
if command -v terraform >/dev/null 2>&1; then
  TF_BIN=(terraform)
elif command -v mise >/dev/null 2>&1; then
  TF_BIN=(mise exec --cd "$REPO_ROOT" -- terraform)
elif $DRY_RUN; then
  TF_BIN=(terraform)
else
  echo "[error] terraform not found on PATH (run: mise trust && mise install)" >&2
  exit 1
fi
TF=("${TF_BIN[@]}" -chdir="$INFRA_DIR")

shopt -s nullglob
TF_FILES=("$INFRA_DIR"/*.tf)
shopt -u nullglob

if [[ ${#TF_FILES[@]} -eq 0 ]]; then
  if $DRY_RUN; then
    echo "[dry-run] Provider '$PROVIDER' resolves to $INFRA_DIR (no *.tf files configured yet)."
    echo "[dry-run] Once populated, would run: ${TF[*]} init && ${TF[*]} $ACTION"
    exit 0
  fi
  echo "[error] No Terraform configuration (*.tf) found in $INFRA_DIR yet." >&2
  exit 1
fi

if [[ "$ACTION" == "validate" ]]; then
  if $DRY_RUN; then
    echo "[dry-run] ${TF[*]} init -backend=false -input=false"
    echo "[dry-run] ${TF[*]} validate"
    exit 0
  fi
  "${TF[@]}" init -backend=false -input=false
  "${TF[@]}" validate
  exit 0
fi

normalize_bool() {
  local raw="$1"
  local name="$2"
  case "${raw,,}" in
    true|1|yes|on) printf 'true' ;;
    false|0|no|off) printf 'false' ;;
    *)
      echo "[error] Invalid boolean value for ${name}: '${raw}' (expected true or false)" >&2
      exit 1
      ;;
  esac
}

normalize_github_repo() {
  local raw="$1"
  if [[ "$raw" =~ ^https?://github\.com/([^/]+/[^/]+)/?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]%.git}"
  else
    raw="${raw#/}"
    raw="${raw%/}"
    printf '%s' "${raw%.git}"
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

tfvars_get_string() {
  local key="$1"
  local file="$INFRA_DIR/terraform.tfvars"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$key" <<'PY'
import re, sys
path, key = sys.argv[1], sys.argv[2]
pattern = re.compile(rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"')
with open(path, encoding="utf-8") as fh:
    for line in fh:
        stripped = line.split("#", 1)[0]
        m = pattern.match(stripped)
        if m:
            print(m.group(1).strip())
            break
PY
}

tfvars_get_bool() {
  local key="$1"
  local file="$INFRA_DIR/terraform.tfvars"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$key" <<'PY'
import re, sys
path, key = sys.argv[1], sys.argv[2]
pattern = re.compile(rf'^\s*{re.escape(key)}\s*=\s*(true|false)\b', re.IGNORECASE)
with open(path, encoding="utf-8") as fh:
    for line in fh:
        stripped = line.split("#", 1)[0]
        m = pattern.match(stripped)
        if m:
            print(m.group(1).lower())
            break
PY
}

dotenv_get_string() {
  local key="$1"
  local file="${2:-$ENV_FILE}"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$key" <<'PY'
import sys
path, target = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        k, v = line.split("=", 1)
        if k.strip() != target:
            continue
        v = v.strip()
        if len(v) >= 2 and ((v[0] == v[-1] == '"') or (v[0] == v[-1] == "'")):
            v = v[1:-1]
        elif " #" in v:
            v = v.split(" #", 1)[0].strip()
        print(v)
        break
PY
}

try_gh_auth() {
  command -v gh >/dev/null 2>&1 || return 1
  local dotenv_gh_token
  dotenv_gh_token="$(dotenv_get_string GH_TOKEN)"
  if [[ -z "${GH_TOKEN:-}" && -n "$GH_TOKEN_CALLER" ]]; then
    export GH_TOKEN="$GH_TOKEN_CALLER"
  elif [[ -z "${GH_TOKEN:-}" && -n "$dotenv_gh_token" ]]; then
    export GH_TOKEN="$dotenv_gh_token"
  fi
  if gh auth status >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "$REPO_ROOT/.env" ]]; then
    local root_tok
    root_tok="$(dotenv_get_string GH_TOKEN "$REPO_ROOT/.env")"
    [[ -z "$root_tok" ]] && root_tok="$(dotenv_get_string GITHUB_TOKEN "$REPO_ROOT/.env")"
    if [[ -n "$root_tok" ]]; then
      export GH_TOKEN="$root_tok"
      if gh auth status >/dev/null 2>&1; then
        return 0
      fi
    fi
  fi
  return 1
}

run_azure_or_onprem_terraform() {
  local approve_args=()
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    approve_args=(-auto-approve)
  fi

  if [[ "$PROVIDER" == "azure" ]] && ! $DRY_RUN && [[ -z "${ARM_SUBSCRIPTION_ID:-}" ]]; then
    if ! command -v az >/dev/null 2>&1; then
      echo "[error] Azure CLI ('az') not found on PATH; run 'az login' or set ARM_SUBSCRIPTION_ID." >&2
      exit 1
    fi
    ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
    ARM_TENANT_ID="${ARM_TENANT_ID:-$(az account show --query tenantId -o tsv 2>/dev/null || true)}"
    if [[ -z "$ARM_SUBSCRIPTION_ID" ]]; then
      echo "[error] No logged-in Azure subscription found. Run 'az login' first." >&2
      exit 1
    fi
    export ARM_SUBSCRIPTION_ID ARM_TENANT_ID
  fi

  if $DRY_RUN; then
    echo "[dry-run] Provider: $PROVIDER ($INFRA_DIR)"
    [[ "$PROVIDER" == "azure" ]] && echo "[dry-run] Credentials: logged-in Azure CLI session (ARM_SUBSCRIPTION_ID from 'az account show')"
    echo "[dry-run] ${TF[*]} init -input=false"
    case "$ACTION" in
      plan) echo "[dry-run] ${TF[*]} plan -input=false" ;;
      apply) echo "[dry-run] ${TF[*]} apply -input=false ${approve_args[*]}" ;;
      destroy) echo "[dry-run] ${TF[*]} destroy -input=false ${approve_args[*]}" ;;
    esac
    return 0
  fi

  "${TF[@]}" init -input=false
  case "$ACTION" in
    plan) "${TF[@]}" plan -input=false ;;
    apply) "${TF[@]}" apply -input=false "${approve_args[@]}" ;;
    destroy) "${TF[@]}" destroy -input=false "${approve_args[@]}" ;;
  esac
}

run_gcp_terraform() {
  local tfvars_project tfvars_region tfvars_zone tfvars_machine tfvars_prefix tfvars_use_spot tfvars_use_default_vpc
  local tfvars_repo tfvars_runner_name tfvars_runner_labels tfvars_runner_user
  tfvars_project="$(tfvars_get_string project_id)"
  tfvars_region="$(tfvars_get_string region)"
  tfvars_zone="$(tfvars_get_string zone)"
  tfvars_machine="$(tfvars_get_string machine_type)"
  tfvars_prefix="$(tfvars_get_string name_prefix)"
  tfvars_use_spot="$(tfvars_get_bool use_spot)"
  tfvars_use_default_vpc="$(tfvars_get_bool use_default_vpc)"
  tfvars_repo="$(tfvars_get_string github_repo)"
  tfvars_runner_name="$(tfvars_get_string runner_name)"
  tfvars_runner_labels="$(tfvars_get_string runner_labels)"
  tfvars_runner_user="$(tfvars_get_string runner_username)"

  [[ -z "$PROJECT_ID" ]] && PROJECT_ID="$(dotenv_get_string PROJECT_ID)"
  [[ -z "$REGION" ]] && REGION="$(dotenv_get_string REGION)"
  local dotenv_zone
  dotenv_zone="$(dotenv_get_string ZONE)"
  [[ -z "$USE_SPOT" ]] && USE_SPOT="$(dotenv_get_string USE_SPOT)"
  [[ -z "$USE_DEFAULT_VPC" ]] && USE_DEFAULT_VPC="$(dotenv_get_string USE_DEFAULT_VPC)"
  [[ -z "$DEFAULT_VPC_NAME" ]] && DEFAULT_VPC_NAME="$(dotenv_get_string DEFAULT_VPC_NAME)"
  [[ -z "$ENABLE_INGRESS_FIREWALLS" ]] && ENABLE_INGRESS_FIREWALLS="$(dotenv_get_string ENABLE_INGRESS_FIREWALLS)"
  [[ -z "$SSH_PROXY_CIDRS" ]] && SSH_PROXY_CIDRS="$(dotenv_get_string SSH_PROXY_CIDRS)"
  [[ -z "$GCP_SSH_HOSTNAME_TEMPLATE" ]] && GCP_SSH_HOSTNAME_TEMPLATE="$(dotenv_get_string GCP_SSH_HOSTNAME_TEMPLATE)"
  [[ -z "$GCP_SSH_TEMPLATE_ACCOUNT_SUFFIX" ]] && GCP_SSH_TEMPLATE_ACCOUNT_SUFFIX="$(dotenv_get_string GCP_SSH_TEMPLATE_ACCOUNT_SUFFIX)"

  [[ -z "$GITHUB_REPO" ]] && GITHUB_REPO="$(dotenv_get_string GITHUB_REPO)"
  [[ -z "$GPU_RUNNER" ]] && GPU_RUNNER="$(dotenv_get_string GPU_RUNNER)"
  [[ -z "$RUNNER_NAME" ]] && RUNNER_NAME="$(dotenv_get_string RUNNER_NAME)"
  [[ -z "$RUNNER_LABELS" ]] && RUNNER_LABELS="$(dotenv_get_string RUNNER_LABELS)"
  [[ -z "$RUNNER_USER" ]] && RUNNER_USER="$(dotenv_get_string RUNNER_USER)"
  [[ -z "$RUNNER_PAT" ]] && RUNNER_PAT="$(dotenv_get_string RUNNER_PAT)"

  local logged_account logged_project
  logged_account="$(gcloud_config_value account)"
  logged_project="$(gcloud_config_value project)"

  local effective_project="${PROJECT_ID:-${logged_project:-${tfvars_project:-}}}"
  if [[ -z "$effective_project" ]]; then
    if $DRY_RUN; then
      effective_project="<gcloud-active-project>"
    else
      echo "[error] No active GCP project found in logged-in gcloud config." >&2
      echo "[error] Run 'gcloud config set project <PROJECT_ID>' or pass --project=<PROJECT_ID>." >&2
      exit 1
    fi
  fi

  # @google.com accounts enforce Certificate-Based Access (CBA/mTLS) on `gcloud auth print-access-token`,
  # which causes non-mTLS clients like Terraform to fail with `401 ACCESS_TOKEN_TYPE_UNSUPPORTED`.
  # Application Default Credentials (`gcloud auth application-default login`) are exempt from CBA,
  # so automatically use ADC when authenticated as *@google.com.
  local use_adc=false
  case "$AUTH_MODE" in
    adc) use_adc=true ;;
    gcloud) use_adc=false ;;
    auto)
      if [[ "${logged_account,,}" == *@google.com ]]; then
        use_adc=true
      fi
      ;;
  esac

  if [[ -z "$logged_account" && "$use_adc" == "false" ]] && ! $DRY_RUN; then
    echo "[error] No logged-in gcloud account found. Run 'gcloud auth login' first (or pass --adc)." >&2
    exit 1
  fi

  refresh_gcp_credentials() {
    if $use_adc; then
      unset GOOGLE_OAUTH_ACCESS_TOKEN
      local adc_file="${GOOGLE_APPLICATION_CREDENTIALS:-${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json}"
      if [[ ! -f "$adc_file" ]]; then
        echo "[error] Application Default Credentials not found at $adc_file." >&2
        echo "[error] Run 'gcloud auth application-default login' first." >&2
        exit 1
      fi
      return 0
    fi
    if ! GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null)" || [[ -z "$GOOGLE_OAUTH_ACCESS_TOKEN" ]]; then
      echo "[error] Failed to obtain access token from logged-in gcloud session. Run 'gcloud auth login' (or pass --adc)." >&2
      exit 1
    fi
    export GOOGLE_OAUTH_ACCESS_TOKEN
  }

  local effective_use_spot
  effective_use_spot="$(normalize_bool "${USE_SPOT:-${tfvars_use_spot:-true}}" "USE_SPOT")"

  local effective_use_default_vpc=""
  if [[ -n "$USE_DEFAULT_VPC" ]]; then
    effective_use_default_vpc="$(normalize_bool "$USE_DEFAULT_VPC" "USE_DEFAULT_VPC")"
  elif [[ -n "$tfvars_use_default_vpc" ]]; then
    effective_use_default_vpc="$(normalize_bool "$tfvars_use_default_vpc" "use_default_vpc")"
  fi

  local effective_enable_ingress_firewalls=""
  if [[ -n "$ENABLE_INGRESS_FIREWALLS" ]]; then
    effective_enable_ingress_firewalls="$(normalize_bool "$ENABLE_INGRESS_FIREWALLS" "ENABLE_INGRESS_FIREWALLS")"
  fi

  # Region & Zone resolution: explicit CLI --zone overrides region; explicit CLI --region
  # ignores a conflicting .env/tfvars zone from another region.
  local explicit_region="$REGION"
  local default_region="${REGION:-${tfvars_region:-europe-west4}}"
  local explicit_zone="${CLI_ZONE:-${ZONE:-}}"
  if [[ -z "$explicit_zone" ]]; then
    local fallback_zone="${dotenv_zone:-${tfvars_zone:-}}"
    if [[ -n "$fallback_zone" ]]; then
      if [[ -z "$CLI_REGION" || "${fallback_zone%-*}" == "$CLI_REGION" ]]; then
        explicit_zone="$fallback_zone"
      fi
    fi
  fi
  if [[ -n "$CLI_ZONE" && -z "$CLI_REGION" ]]; then
    default_region="${CLI_ZONE%-*}"
    explicit_region="$default_region"
  elif [[ -n "$explicit_zone" && -z "$explicit_region" && -z "$tfvars_region" ]]; then
    default_region="${explicit_zone%-*}"
  fi
  local default_zone="${explicit_zone:-${default_region}-a}"

  local effective_machine="${MACHINE_TYPE:-${tfvars_machine:-g4-standard-192}}"
  local effective_prefix="${NAME_PREFIX:-${tfvars_prefix:-dev-gpu}}"
  local tf_workspace="${TF_WORKSPACE:-$effective_project}"

  local effective_repo
  effective_repo="$(normalize_github_repo "${GITHUB_REPO:-${tfvars_repo:-vitorecomp/personal-infra}}")"
  local effective_gpu_runner="${GPU_RUNNER:-${PROVIDER}-gpu}"
  local effective_runner_name="${RUNNER_NAME:-${tfvars_runner_name:-${PROVIDER}-gpu-runner}}"
  local effective_runner_labels="${RUNNER_LABELS:-${tfvars_runner_labels:-self-hosted,linux,x64,${effective_gpu_runner}}}"
  local effective_runner_user="${RUNNER_USER:-${tfvars_runner_user:-github-runner}}"

  local tf_ssh_proxy_cidrs_json=""
  if [[ -n "$SSH_PROXY_CIDRS" ]]; then
    tf_ssh_proxy_cidrs_json="$(python3 - "$SSH_PROXY_CIDRS" <<'PY'
import json, sys
items = [c.strip() for c in sys.argv[1].split(",") if c.strip()]
print(json.dumps(items) if items else "")
PY
)"
  fi

  local effective_ssh_template=""
  if [[ -n "$GCP_SSH_HOSTNAME_TEMPLATE" ]]; then
    if [[ -z "$GCP_SSH_TEMPLATE_ACCOUNT_SUFFIX" || "${logged_account,,}" == *"${GCP_SSH_TEMPLATE_ACCOUNT_SUFFIX,,}" ]]; then
      effective_ssh_template="$GCP_SSH_HOSTNAME_TEMPLATE"
    fi
  fi

  local var_args=()
  local apply_args=()
  build_tf_args() {
    local target_region="$1"
    local target_zone="$2"
    var_args=(
      -input=false
      -var="project_id=${effective_project}"
      -var="region=${target_region}"
      -var="zone=${target_zone}"
      -var="use_spot=${effective_use_spot}"
      -var="enable_public_ingress=false"
      -var="github_repo=${effective_repo}"
      -var="runner_name=${effective_runner_name}"
      -var="runner_labels=${effective_runner_labels}"
      -var="runner_username=${effective_runner_user}"
    )
    if [[ -n "$effective_use_default_vpc" ]]; then
      var_args+=(-var="use_default_vpc=${effective_use_default_vpc}")
    fi
    if [[ -n "$DEFAULT_VPC_NAME" ]]; then
      var_args+=(-var="default_vpc_name=${DEFAULT_VPC_NAME}")
    fi
    if [[ -n "$effective_enable_ingress_firewalls" ]]; then
      var_args+=(-var="enable_ingress_firewalls=${effective_enable_ingress_firewalls}")
    fi
    if [[ -n "$tf_ssh_proxy_cidrs_json" ]]; then
      var_args+=(-var="ssh_proxy_cidrs=${tf_ssh_proxy_cidrs_json}")
    fi
    if [[ -n "$effective_ssh_template" ]]; then
      var_args+=(-var="ssh_hostname_template=${effective_ssh_template}")
    fi
    if [[ -n "$MACHINE_TYPE" ]]; then
      var_args+=(-var="machine_type=${MACHINE_TYPE}")
    fi
    if [[ -n "$NAME_PREFIX" ]]; then
      var_args+=(-var="name_prefix=${NAME_PREFIX}")
    fi

    apply_args=("${var_args[@]}")
    if [[ "$AUTO_APPROVE" == "true" ]]; then
      apply_args+=(-auto-approve)
    fi
  }

  local provisioning_desc="SPOT (auto-healed by MIG; use_spot=true)"
  if [[ "$effective_use_spot" == "false" ]]; then
    provisioning_desc="STANDARD (on-demand; use_spot=false)"
  fi

  local vpc_mode_desc="custom VPC (${effective_prefix}-vpc)"
  if [[ "${effective_use_default_vpc}" == "true" ]]; then
    vpc_mode_desc="existing VPC (${DEFAULT_VPC_NAME:-default})"
  fi

  local runner_auth_desc="gh api registration-token"
  if [[ -n "$RUNNER_PAT" ]]; then
    runner_auth_desc="RUNNER_PAT"
  elif [[ -n "${TF_VAR_runner_token:-}" ]]; then
    runner_auth_desc="TF_VAR_runner_token"
  fi

  if $DRY_RUN; then
    build_tf_args "$default_region" "$default_zone"
    echo "[dry-run] Provider:             gcp ($INFRA_DIR)"
    echo "[dry-run] Action:               $ACTION"
    if (( LOOP_MINUTES > 0 )); then
      echo "[dry-run] Retry Loop:           every ${LOOP_MINUTES} minute(s) until success (stage_on_exhaustion=$STAGE_ON_EXHAUSTION)"
    fi
    if $use_adc; then
      echo "[dry-run] Credentials:          Application Default Credentials (${logged_account:-ADC})"
    else
      echo "[dry-run] Credentials:          logged-in gcloud account (${logged_account:-<gcloud-active-account>})"
    fi
    echo "[dry-run] Project / Workspace:  $effective_project / $tf_workspace"
    echo "[dry-run] Region / Zone:        $default_region / $default_zone (cycle_regions=$CYCLE_REGIONS${REGIONS_LIST:+, regions=$REGIONS_LIST})"
    echo "[dry-run] Provisioning Model:   $provisioning_desc"
    echo "[dry-run] VPC Network:          $vpc_mode_desc"
    echo "[dry-run] Machine / Prefix:     $effective_machine / $effective_prefix"
    echo "[dry-run] Runner Bootstrap:     Secret Manager (${effective_prefix}-runner-bootstrap -> ${effective_repo}, auth=${runner_auth_desc})"
    echo "[dry-run] Commands:"
    $use_adc || echo "[dry-run]   export GOOGLE_OAUTH_ACCESS_TOKEN=\"\$(gcloud auth print-access-token)\""
    echo "[dry-run]   gcloud services enable compute.googleapis.com secretmanager.googleapis.com iap.googleapis.com oslogin.googleapis.com iam.googleapis.com --project=$effective_project --quiet"
    if [[ "$ACTION" == "apply" ]]; then
      if [[ -n "$RUNNER_PAT" ]]; then
        echo "[dry-run]   export TF_VAR_runner_pat=\"<redacted>\""
      else
        echo "[dry-run]   export TF_VAR_runner_token=\"\$(gh api -X POST repos/${effective_repo}/actions/runners/registration-token -q .token)\""
      fi
    fi
    echo "[dry-run]   ${TF[*]} init -input=false"
    echo "[dry-run]   ${TF[*]} workspace select -or-create $tf_workspace"
    case "$ACTION" in
      plan) echo "[dry-run]   ${TF[*]} plan ${var_args[*]}" ;;
      destroy) echo "[dry-run]   ${TF[*]} destroy ${apply_args[*]}" ;;
      apply)
        echo "[dry-run]   ${TF[*]} apply ${apply_args[*]}"
        echo "[dry-run]   gcloud compute instance-groups managed list-instances ${effective_prefix}-mig --zone=${default_zone} --project=${effective_project} --format=json  # poll until RUNNING"
        echo "[dry-run]   gcloud compute disks update <MIG data disk> --provisioned-iops=<tf output data_disk_iops> --provisioned-throughput=<tf output data_disk_throughput_mbps>  # in place, only if different"
        ;;
    esac
    return 0
  fi

  if ! command -v gcloud >/dev/null 2>&1; then
    echo "[error] gcloud CLI is required for --provider=gcp." >&2
    exit 1
  fi

  # Pass sensitive runner auth via TF_VAR_* env vars (never via -var CLI args).
  prepare_runner_bootstrap_auth() {
    if [[ -n "$RUNNER_PAT" ]]; then
      export TF_VAR_runner_pat="$RUNNER_PAT"
      return 0
    fi
    if [[ -n "${TF_VAR_runner_token:-}" ]]; then
      return 0
    fi
    if [[ "$ACTION" == "apply" ]]; then
      if try_gh_auth && [[ -n "$effective_repo" ]]; then
        local minted_token
        minted_token="$(gh api -X POST "repos/${effective_repo}/actions/runners/registration-token" -q .token 2>/dev/null || true)"
        if [[ -n "$minted_token" ]]; then
          export TF_VAR_runner_token="$minted_token"
          echo "Minted GitHub Actions runner registration token for ${effective_repo} (injected into Secret Manager via TF_VAR_runner_token)."
        else
          echo "[warn] Failed to mint GitHub runner registration token for ${effective_repo}; continuing (stateful /mnt/data/actions-runner/.credentials will still be reused if present)." >&2
        fi
      else
        echo "[warn] 'gh' CLI is not authenticated and RUNNER_PAT is unset; skipping runner registration-token minting. Run 'gh auth login' or set RUNNER_PAT in development/.env so a new GPU VM can self-register." >&2
      fi
    elif [[ "$ACTION" == "plan" ]]; then
      if ! try_gh_auth; then
        echo "[warn] 'gh' CLI is not authenticated and RUNNER_PAT is unset; proceeding with plan (run 'gh auth login' or set RUNNER_PAT before apply)." >&2
      fi
    fi
  }

  refresh_gcp_credentials
  if $use_adc; then
    echo "Using Application Default Credentials (active gcloud account: ${logged_account:-ADC}) and project: ${effective_project}"
  else
    echo "Using logged-in GCP credentials (${logged_account:-gcloud}) and project: ${effective_project}"
  fi
  echo "Provisioning model: ${provisioning_desc}; VPC: ${vpc_mode_desc}; Runner: ${effective_runner_name} -> ${effective_repo}."

  echo "Enabling required GCP APIs (compute, secretmanager, iap, oslogin, iam) in project: ${effective_project}..."
  gcloud services enable \
    compute.googleapis.com \
    secretmanager.googleapis.com \
    iap.googleapis.com \
    oslogin.googleapis.com \
    iam.googleapis.com \
    --project="${effective_project}" \
    --quiet

  echo "Initializing Terraform in ${INFRA_DIR}..."
  "${TF[@]}" init -input=false >/dev/null
  "${TF[@]}" workspace select -or-create "${tf_workspace}" >/dev/null

  # Idempotently migrate legacy un-indexed VPC/subnet state addresses if present.
  local cur_state_list
  cur_state_list="$("${TF[@]}" state list 2>/dev/null || true)"
  if [[ -n "$cur_state_list" ]]; then
    local legacy_addr
    for legacy_addr in google_compute_network.vpc google_compute_subnetwork.subnet; do
      if grep -qxF "$legacy_addr" <<< "$cur_state_list" && ! grep -qxF "${legacy_addr}[0]" <<< "$cur_state_list"; then
        "${TF[@]}" state mv "$legacy_addr" "${legacy_addr}[0]" >/dev/null 2>&1 || true
      fi
    done
  fi

  # Inspect current Terraform state for an existing Stateful MIG (and any legacy 2-VM resources).
  local raw_state_json state_mig_zone state_mig_name tainted_mig_zone legacy_gpu_zone legacy_ctrl_zone legacy_data_zone
  raw_state_json="$("${TF[@]}" state pull 2>/dev/null || true)"
  read -r state_mig_zone state_mig_name tainted_mig_zone legacy_gpu_zone legacy_ctrl_zone legacy_data_zone < <(
    printf '%s' "$raw_state_json" | python3 -c '
import json, sys
default_prefix = sys.argv[1]
try:
    s = json.load(sys.stdin)
except Exception:
    print(f"- {default_prefix}-mig - - - -")
    sys.exit(0)
mig_zone = tainted_mig_zone = legacy_gpu_zone = legacy_ctrl_zone = legacy_data_zone = "-"
mig_name = f"{default_prefix}-mig"
for r in s.get("resources", []):
    insts = r.get("instances", [])
    if not insts:
        continue
    inst0 = insts[0]
    attrs = inst0.get("attributes", {})
    rtype, rname = r.get("type"), r.get("name")
    if rtype == "google_compute_instance_group_manager" and rname == "gpu":
        z = attrs.get("zone") or "-"
        if attrs.get("name"):
            mig_name = attrs["name"]
        if inst0.get("status") == "tainted" or not attrs.get("self_link"):
            tainted_mig_zone = z
        else:
            mig_zone = z
    elif rtype == "google_compute_instance" and rname == "gpu_vm":
        legacy_gpu_zone = attrs.get("zone") or "-"
    elif rtype == "google_compute_instance" and rname == "controller":
        legacy_ctrl_zone = attrs.get("zone") or "-"
    elif rtype == "google_compute_disk" and rname == "gpu_data":
        legacy_data_zone = attrs.get("zone") or "-"
print(f"{mig_zone} {mig_name} {tainted_mig_zone} {legacy_gpu_zone} {legacy_ctrl_zone} {legacy_data_zone}")
' "$effective_prefix"
  )

  # Clean up any tainted/uncreated MIG state stub from a failed prior apply so Terraform
  # does not fail refreshing a non-existent MIG or mis-detect it as active.
  if [[ "$tainted_mig_zone" != "-" && "$ACTION" == "apply" ]]; then
    "${TF[@]}" state rm google_compute_instance_group_manager.gpu >/dev/null 2>&1 || true
  fi

  local pinned_plan_region="$default_region"
  local pinned_plan_zone="$default_zone"
  if [[ -z "$CLI_ZONE" && "$state_mig_zone" != "-" ]]; then
    pinned_plan_zone="$state_mig_zone"
    if [[ -z "$CLI_REGION" ]]; then pinned_plan_region="${state_mig_zone%-*}"; fi
  elif [[ -z "$CLI_ZONE" && "$tainted_mig_zone" != "-" ]]; then
    pinned_plan_zone="$tainted_mig_zone"
    if [[ -z "$CLI_REGION" ]]; then pinned_plan_region="${tainted_mig_zone%-*}"; fi
  elif [[ -z "$CLI_ZONE" && "$legacy_gpu_zone" != "-" ]]; then
    pinned_plan_zone="$legacy_gpu_zone"
    if [[ -z "$CLI_REGION" ]]; then pinned_plan_region="${legacy_gpu_zone%-*}"; fi
  elif [[ -z "$CLI_ZONE" && "$legacy_ctrl_zone" != "-" ]]; then
    pinned_plan_zone="$legacy_ctrl_zone"
    if [[ -z "$CLI_REGION" ]]; then pinned_plan_region="${legacy_ctrl_zone%-*}"; fi
  fi

  if [[ "$ACTION" == "plan" ]]; then
    prepare_runner_bootstrap_auth
    refresh_gcp_credentials
    build_tf_args "$pinned_plan_region" "$pinned_plan_zone"
    "${TF[@]}" plan "${var_args[@]}"
    return 0
  fi

  if [[ "$ACTION" == "destroy" ]]; then
    refresh_gcp_credentials
    build_tf_args "$pinned_plan_region" "$pinned_plan_zone"
    "${TF[@]}" destroy "${apply_args[@]}"
    return 0
  fi

  prepare_runner_bootstrap_auth

  if [[ "$legacy_gpu_zone" != "-" || "$legacy_ctrl_zone" != "-" || "$legacy_data_zone" != "-" ]]; then
    echo "Detected legacy standalone 2-VM resources in Terraform state (controller=${legacy_ctrl_zone}, gpu_vm=${legacy_gpu_zone}, data=${legacy_data_zone}); releasing them before creating Stateful MIG so GPU/disk quota is free..."
    local -a legacy_targets=()
    for legacy_res in \
      google_compute_instance.gpu_vm \
      google_compute_instance.controller \
      google_compute_disk.gpu_data; do
      if grep -qxF "$legacy_res" <<< "$cur_state_list"; then
        legacy_targets+=(-target="$legacy_res")
      fi
    done
    if [[ ${#legacy_targets[@]} -gt 0 ]]; then
      refresh_gcp_credentials
      build_tf_args "$pinned_plan_region" "$pinned_plan_zone"
      "${TF[@]}" destroy -auto-approve "${var_args[@]}" "${legacy_targets[@]}" || true
    fi
  fi

  # Check whether an existing Stateful MIG in state currently has a RUNNING instance.
  local state_mig_running="false"
  if [[ "$state_mig_zone" != "-" ]]; then
    local state_mig_list_json
    state_mig_list_json="$(gcloud compute instance-groups managed list-instances "$state_mig_name" \
      --zone="$state_mig_zone" \
      --project="$effective_project" \
      --format=json 2>/dev/null || true)"
    state_mig_running="$(
      printf '%s' "$state_mig_list_json" | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin)
except Exception:
    print("false")
    sys.exit(0)
running = any(isinstance(x, dict) and (x.get("instanceStatus") or "").upper() == "RUNNING" for x in (items if isinstance(items, list) else []))
print("true" if running else "false")
'
    )"
  fi

  local candidate_targets=()
  if [[ -n "$CLI_ZONE" ]]; then
    candidate_targets=("${CLI_ZONE%-*}:${CLI_ZONE}")
  elif [[ "$state_mig_zone" != "-" && "$FORCE_MOVE" != "true" ]] && \
       { [[ "$state_mig_running" == "true" ]] || [[ "$CYCLE_REGIONS" != "true" && -z "$REGIONS_LIST" ]]; }; then
    local pinned_region="${state_mig_zone%-*}"
    echo "Pinning deployment to existing Stateful MIG '${state_mig_name}' in state: ${pinned_region} / ${state_mig_zone} (running=${state_mig_running})"
    candidate_targets=("${pinned_region}:${state_mig_zone}")
  elif [[ "$CYCLE_REGIONS" != "true" && -z "$REGIONS_LIST" && -n "$explicit_zone" ]]; then
    candidate_targets=("${explicit_zone%-*}:${explicit_zone}")
  else
    echo "Discovering zones offering ${effective_machine} in project ${effective_project}..."
    local preferred_state_zone="$state_mig_zone"
    if [[ "$preferred_state_zone" == "-" ]]; then
      preferred_state_zone="$tainted_mig_zone"
    fi
    if [[ "$preferred_state_zone" == "-" ]]; then
      preferred_state_zone="$legacy_data_zone"
    fi
    if [[ -z "$explicit_region" && -z "$CLI_ZONE" && "$preferred_state_zone" != "-" ]]; then
      default_region="${preferred_state_zone%-*}"
    fi
    local all_machine_zones
    all_machine_zones="$(gcloud compute machine-types list \
      --project="${effective_project}" \
      --filter="name=${effective_machine}" \
      --format="value(zone)" 2>/dev/null | sort -u || true)"

    mapfile -t candidate_targets < <(
      python3 - "$default_region" "$REGIONS_LIST" "$CYCLE_REGIONS" "$preferred_state_zone" "$all_machine_zones" <<'PY'
import sys

default_region = sys.argv[1]
regions_csv = sys.argv[2]
cycle_all = sys.argv[3] == "true"
state_zone = sys.argv[4]
all_zones = [z.strip() for z in sys.argv[5].splitlines() if z.strip()]

by_region = {}
for z in all_zones:
    r = z.rsplit("-", 1)[0]
    by_region.setdefault(r, []).append(z)

preferred_order = [
    default_region,
    "europe-west4", "europe-west1", "europe-west2", "europe-north1",
    "europe-west8", "europe-west10",
    "us-central1", "us-east4", "us-east5", "us-east1", "us-south1",
    "us-west1", "us-west4", "us-west3",
    "southamerica-east1",
    "asia-southeast1", "asia-northeast1", "asia-east1", "asia-northeast3",
    "asia-south1", "asia-south2", "asia-southeast2",
    "me-central2", "australia-southeast2",
]

if regions_csv:
    target_regions = [r.strip() for r in regions_csv.split(",") if r.strip()]
elif cycle_all:
    target_regions = []
    for r in preferred_order + sorted(by_region.keys()):
        if r in by_region and r not in target_regions:
            target_regions.append(r)
else:
    target_regions = [default_region]

seen = set()
out = []
for r in target_regions:
    zones = list(by_region.get(r, []))
    if not zones and not all_zones:
        zones = [f"{r}-a", f"{r}-b", f"{r}-c"]
    if state_zone != "-" and state_zone in zones:
        zones.remove(state_zone)
        zones.insert(0, state_zone)
    for z in zones:
        key = f"{r}:{z}"
        if key not in seen:
            seen.add(key)
            out.append(key)

for item in out:
    print(item)
PY
    )
  fi

  if [[ ${#candidate_targets[@]} -eq 0 ]]; then
    echo "[error] No valid zones found for machine type ${effective_machine} in requested region(s)." >&2
    exit 1
  fi

  echo "Candidate region/zone order (${#candidate_targets[@]}): ${candidate_targets[*]}"

  has_more_candidates() {
    local cur_idx="$1"
    local skipped_reg="$2"
    local j next_target next_reg
    for ((j = cur_idx + 1; j < ${#candidate_targets[@]}; j++)); do
      next_target="${candidate_targets[$j]}"
      next_reg="${next_target%%:*}"
      if [[ -z "$skipped_reg" || "$next_reg" != "$skipped_reg" ]]; then
        return 0
      fi
    done
    return 1
  }

  destroy_mig_in_zone() {
    local target_region="$1"
    local target_zone="$2"
    refresh_gcp_credentials
    build_tf_args "$target_region" "$target_zone"
    "${TF[@]}" destroy -auto-approve "${var_args[@]}" \
      -target=google_compute_instance_group_manager.gpu \
      -target=google_compute_instance_template.gpu || true
  }

  classify_mig_instances_json() {
    python3 -c '
import json, re, sys

raw = sys.stdin.read().strip()
if not raw:
    print("WAITING\t-\t-\tno instances reported yet")
    sys.exit(0)
try:
    items = json.loads(raw)
except Exception as exc:
    msg = " ".join(str(exc).split())
    print(f"WAITING\t-\t-\tinvalid json: {msg}")
    sys.exit(0)
if not isinstance(items, list) or not items:
    print("WAITING\t-\t-\tmig creating instance")
    sys.exit(0)

entry = items[0] if isinstance(items[0], dict) else {}
inst_url = entry.get("instance") or ""
inst_name = inst_url.rsplit("/", 1)[-1] if inst_url else "-"
inst_status = (entry.get("instanceStatus") or "").upper()
cur_action = (entry.get("currentAction") or "").upper()

la = entry.get("lastAttempt") or {}
errs_obj = la.get("errors") or {}
if isinstance(errs_obj, dict):
    errs = errs_obj.get("errors") or []
elif isinstance(errs_obj, list):
    errs = errs_obj
else:
    errs = []

err_texts = []
for e in errs:
    if isinstance(e, dict):
        code = str(e.get("code") or "")
        msg = str(e.get("message") or "")
        err_texts.append(f"{code}: {msg}".strip(": "))
    else:
        err_texts.append(str(e))
combined_err = " ".join(" | ".join(err_texts).split())

status_label = inst_status or "NONE"
action_label = cur_action or "NONE"

if inst_status == "RUNNING":
    print(f"RUNNING\t{inst_name}\t{inst_status}\taction={action_label}")
    sys.exit(0)
if inst_status in ("PROVISIONING", "STAGING"):
    print(f"BOOTING\t{inst_name}\t{inst_status}\taction={action_label}")
    sys.exit(0)
if combined_err:
    if re.search(r"QUOTA_EXCEEDED|Quota\b.*\bexceeded", combined_err, re.IGNORECASE):
        print(f"QUOTA\t{inst_name}\t{status_label}\t{combined_err}")
        sys.exit(0)
    if re.search(r"ZONE_RESOURCE_POOL_EXHAUSTED|RESOURCE_POOL_EXHAUSTED|does not have enough resources|stockout|preempted", combined_err, re.IGNORECASE):
        print(f"EXHAUSTED\t{inst_name}\t{status_label}\t{combined_err}")
        sys.exit(0)
    print(f"ERROR\t{inst_name}\t{status_label}\t{combined_err}")
    sys.exit(0)

print(f"WAITING\t{inst_name}\t{status_label}\taction={action_label}")
'
  }

  local deployed_region=""
  local deployed_zone=""
  local mig_instance_state="UNKNOWN"
  local exhausted_target=""
  local skip_region=""
  local current_state_zone="$state_mig_zone"
  local log_file
  log_file="$(mktemp)"
  trap 'rm -f "${log_file:-}"' EXIT

  apply_full_stack() {
    local target_region="$1"
    local target_zone="$2"
    refresh_gcp_credentials
    build_tf_args "$target_region" "$target_zone"
    : > "$log_file"
    set +e
    "${TF[@]}" apply "${apply_args[@]}" 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e

    if [[ $rc -ne 0 ]] && [[ "${effective_use_default_vpc}" == "true" ]] && \
       grep -Eq "networks/${effective_prefix}-vpc' is already being used by 'projects/.*/global/firewalls/" "$log_file"; then
      echo "Cleaning up unmanaged firewall rules blocking removal of unused ${effective_prefix}-vpc..."
      local extra_fws
      extra_fws="$(gcloud compute firewall-rules list \
        --project="${effective_project}" \
        --filter="network ~ /networks/${effective_prefix}-vpc$" \
        --format="value(name)" 2>/dev/null || true)"
      if [[ -n "$extra_fws" ]]; then
        # shellcheck disable=SC2086
        gcloud compute firewall-rules delete $extra_fws --project="${effective_project}" --quiet 2>/dev/null || true
      fi
      refresh_gcp_credentials
      if "${TF[@]}" apply "${apply_args[@]}"; then
        return 0
      fi
      echo "Detaching externally locked ${effective_prefix}-vpc from Terraform state..."
      "${TF[@]}" state rm 'google_compute_network.vpc[0]' 2>/dev/null || "${TF[@]}" state rm 'google_compute_network.vpc' 2>/dev/null || true
      "${TF[@]}" apply "${apply_args[@]}"
      return $?
    fi
    return "$rc"
  }

  for idx in "${!candidate_targets[@]}"; do
    local target="${candidate_targets[$idx]}"
    local cand_region="${target%%:*}"
    local cand_zone="${target##*:}"

    if [[ -n "$skip_region" && "$cand_region" == "$skip_region" ]]; then
      continue
    fi

    # When moving an existing MIG to a different zone/region, tear down the old MIG and
    # template first so regional subnetwork replacement never hits a dependency cycle.
    if [[ "$current_state_zone" != "-" && "$current_state_zone" != "$cand_zone" ]]; then
      echo "Releasing previous Stateful MIG in ${current_state_zone} before moving to ${cand_zone}..."
      destroy_mig_in_zone "${current_state_zone%-*}" "$current_state_zone"
      current_state_zone="-"
    fi

    echo "Trying region ${cand_region} / zone ${cand_zone} ($((idx + 1))/${#candidate_targets[@]})..."
    set +e
    apply_full_stack "$cand_region" "$cand_zone"
    local apply_status=$?
    set -e

    if [[ $apply_status -ne 0 ]]; then
      if grep -Eqi "QUOTA_EXCEEDED|Quota .* exceeded" "$log_file"; then
        echo "Region ${cand_region} hit quota limit during apply; skipping remaining zones in ${cand_region}..."
        skip_region="$cand_region"
        continue
      fi
      if grep -Eqi "ZONE_RESOURCE_POOL_EXHAUSTED|RESOURCE_POOL_EXHAUSTED|does not have enough resources|stockout" "$log_file"; then
        echo "Zone ${cand_zone} reported capacity exhaustion during apply; trying next candidate..."
        exhausted_target="${cand_region}:${cand_zone}"
        continue
      fi
      exit "$apply_status"
    fi

    current_state_zone="$cand_zone"
    local mig_name
    mig_name="$("${TF[@]}" output -raw mig_name 2>/dev/null || echo "${effective_prefix}-mig")"

    echo "Polling Stateful MIG '${mig_name}' in ${cand_zone} for RUNNING instance (up to 90s)..."
    local mig_result="TIMEOUT"
    local last_inst_name="-"
    local last_inst_status="NONE"
    local last_detail=""
    local prev_poll_summary=""
    local poll_attempt

    for poll_attempt in $(seq 1 18); do
      local list_json poll_state inst_name inst_status detail_msg
      list_json="$(gcloud compute instance-groups managed list-instances "$mig_name" \
        --zone="$cand_zone" \
        --project="$effective_project" \
        --format=json 2>/dev/null || true)"
      IFS=$'\t' read -r poll_state inst_name inst_status detail_msg < <(
        printf '%s' "$list_json" | classify_mig_instances_json
      )
      last_inst_name="$inst_name"
      last_inst_status="$inst_status"
      last_detail="$detail_msg"

      local poll_summary="${poll_state}:${inst_name}:${inst_status}:${detail_msg}"
      if [[ "$poll_summary" != "$prev_poll_summary" ]]; then
        echo "  [poll ${poll_attempt}/18] instance=${inst_name} status=${inst_status} state=${poll_state} (${detail_msg})"
        prev_poll_summary="$poll_summary"
      fi

      case "$poll_state" in
        RUNNING)
          mig_result="RUNNING"
          break
          ;;
        QUOTA)
          mig_result="QUOTA"
          break
          ;;
        EXHAUSTED)
          mig_result="EXHAUSTED"
          break
          ;;
        BOOTING)
          if [[ "$poll_attempt" -eq 18 ]]; then
            mig_result="BOOTING"
          else
            sleep 5
          fi
          ;;
        ERROR)
          if [[ "$poll_attempt" -eq 18 ]]; then
            mig_result="ERROR"
          else
            sleep 5
          fi
          ;;
        *)
          if [[ "$poll_attempt" -lt 18 ]]; then
            sleep 5
          fi
          ;;
      esac
    done

    case "$mig_result" in
      RUNNING)
        echo "Managed GPU instance '${last_inst_name}' is RUNNING in ${cand_zone}."
        deployed_region="$cand_region"
        deployed_zone="$cand_zone"
        mig_instance_state="RUNNING"
        break
        ;;
      BOOTING)
        echo "Managed GPU instance '${last_inst_name}' is allocated and booting (${last_inst_status}) in ${cand_zone}."
        deployed_region="$cand_region"
        deployed_zone="$cand_zone"
        mig_instance_state="$last_inst_status"
        break
        ;;
      QUOTA)
        echo "Region ${cand_region} hit quota limit (${last_detail}); skipping remaining zones in ${cand_region}..."
        skip_region="$cand_region"
        destroy_mig_in_zone "$cand_region" "$cand_zone"
        current_state_zone="-"
        continue
        ;;
      EXHAUSTED|TIMEOUT)
        exhausted_target="${cand_region}:${cand_zone}"
        if has_more_candidates "$idx" "$skip_region" || [[ "$STAGE_ON_EXHAUSTION" != "true" ]]; then
          echo "Zone ${cand_zone} has no immediate GPU capacity (${last_detail}); destroying MIG before trying next candidate..."
          destroy_mig_in_zone "$cand_region" "$cand_zone"
          current_state_zone="-"
          continue
        else
          echo "Zone ${cand_zone} has no immediate GPU capacity (${last_detail}); leaving Stateful MIG '${mig_name}' active to auto-allocate once capacity opens."
          deployed_region="$cand_region"
          deployed_zone="$cand_zone"
          mig_instance_state="PENDING_CAPACITY"
          break
        fi
        ;;
      ERROR)
        echo "[error] Stateful MIG '${mig_name}' in ${cand_zone} reported an error: ${last_detail}" >&2
        if has_more_candidates "$idx" "$skip_region"; then
          destroy_mig_in_zone "$cand_region" "$cand_zone"
          current_state_zone="-"
          continue
        fi
        exit 1
        ;;
    esac
  done

  # If the final candidates hit quota after an earlier quota-valid zone hit stockout,
  # stage the Stateful MIG in the quota-valid zone when STAGE_ON_EXHAUSTION=true.
  if [[ -z "$deployed_zone" && -n "$exhausted_target" && "$STAGE_ON_EXHAUSTION" == "true" ]]; then
    local fb_region="${exhausted_target%%:*}"
    local fb_zone="${exhausted_target##*:}"
    echo "All candidate regions/zones out of immediate GPU capacity; keeping Stateful MIG active in ${fb_zone} to auto-allocate as soon as capacity opens..."
    apply_full_stack "$fb_region" "$fb_zone"
    deployed_region="$fb_region"
    deployed_zone="$fb_zone"
    mig_instance_state="PENDING_CAPACITY"
  fi

  if [[ -z "$deployed_zone" ]]; then
    echo "[error] Failed to allocate GPU capacity across candidates: ${candidate_targets[*]}" >&2
    exit 1
  fi

  local out_mig_name out_vpc out_secret out_runner_name out_use_spot out_list_cmd
  out_mig_name="$("${TF[@]}" output -raw mig_name 2>/dev/null || echo "${effective_prefix}-mig")"
  out_vpc="$("${TF[@]}" output -raw vpc_network 2>/dev/null || echo "${vpc_mode_desc}")"
  out_secret="$("${TF[@]}" output -raw runner_secret_id 2>/dev/null || echo "${effective_prefix}-runner-bootstrap")"
  out_runner_name="$("${TF[@]}" output -raw runner_name 2>/dev/null || echo "${effective_runner_name}")"
  out_use_spot="$("${TF[@]}" output -raw use_spot 2>/dev/null || echo "${effective_use_spot}")"
  out_list_cmd="$("${TF[@]}" output -raw list_instances_command 2>/dev/null || echo "gcloud compute instance-groups managed list-instances ${out_mig_name} --zone=${deployed_zone} --project=${effective_project}")"

  # The MIG re-attaches the existing stateful `data` disk on every recreation, so the template's IOPS/throughput only
  # apply to brand-new disks. Bring the attached data disk to the Terraform values in place (idempotent).
  sync_data_disk_performance() {
    local want_iops want_tp inst dev src disk_name disk_zone cur
    want_iops="$("${TF[@]}" output -raw data_disk_iops 2>/dev/null || true)"
    want_tp="$("${TF[@]}" output -raw data_disk_throughput_mbps 2>/dev/null || true)"
    if [[ ! "$want_iops" =~ ^[0-9]+$ || ! "$want_tp" =~ ^[0-9]+$ ]]; then
      echo "[warn] Terraform outputs data_disk_iops/data_disk_throughput_mbps missing; skipping data disk performance sync."
      return 0
    fi
    local found=false
    while IFS= read -r inst; do
      [[ -n "$inst" ]] || continue
      while IFS=$'\t' read -r dev src; do
        [[ "$dev" == "data" && -n "$src" ]] || continue
        found=true
        disk_name="${src##*/}"
        disk_zone="$(sed -E 's#.*/zones/([^/]+)/disks/.*#\1#' <<<"$src")"
        cur="$(gcloud compute disks describe "$disk_name" --zone="$disk_zone" --project="$effective_project" \
          --format='value(provisionedIops,provisionedThroughput)' 2>/dev/null || true)"
        if [[ "$cur" == "${want_iops}"$'\t'"${want_tp}" ]]; then
          echo "[ok] Data disk ${disk_name}: ${want_iops} IOPS / ${want_tp} MiB/s already provisioned."
          continue
        fi
        echo "[deploy] Data disk ${disk_name}: ${cur/$'\t'/ IOPS \/ } MiB/s -> ${want_iops} IOPS / ${want_tp} MiB/s (in place, no detach)..."
        if ! gcloud compute disks update "$disk_name" --zone="$disk_zone" --project="$effective_project" \
             --provisioned-iops="$want_iops" --provisioned-throughput="$want_tp" --quiet; then
          echo "[warn] Could not update ${disk_name} (Hyperdisk performance can only be changed every few hours); re-run deploy.sh later."
        fi
      done < <(gcloud compute instances describe "$inst" --zone="$deployed_zone" --project="$effective_project" \
                 --flatten=disks --format='value(disks.deviceName,disks.source)' 2>/dev/null || true)
    done < <(gcloud compute instance-groups managed list-instances "$out_mig_name" --zone="$deployed_zone" \
               --project="$effective_project" --format='value(instance.basename())' 2>/dev/null || true)
    $found || echo "[info] No MIG instance with a data disk yet; a new disk is created with ${want_iops} IOPS / ${want_tp} MiB/s."
  }
  sync_data_disk_performance

  local final_model_desc="SPOT (auto-healed by MIG)"
  if [[ "${out_use_spot,,}" == "false" ]]; then
    final_model_desc="STANDARD (on-demand)"
  fi

  echo ""
  echo "================================================================"
  echo "Stateful GPU MIG deployed successfully (GCP)"
  echo "================================================================"
  echo "Project:              ${effective_project}"
  echo "Region / Zone:        ${deployed_region} / ${deployed_zone}"
  echo "Provisioning Model:   ${final_model_desc}"
  echo "Machine Type:         ${effective_machine}"
  echo "VPC Network:          ${out_vpc}"
  echo "MIG Name:             ${out_mig_name} (state=${mig_instance_state})"
  echo "Runner Secret:        ${out_secret} -> ${effective_repo} (runner=${out_runner_name})"
  if [[ "$mig_instance_state" == "PENDING_CAPACITY" ]]; then
    echo ""
    echo "Note: The Stateful MIG is active in ${deployed_zone} and will automatically"
    echo "      allocate the GPU VM, attach its 3 TB Hyperdisk, and register the runner"
    echo "      as soon as capacity becomes available."
  fi
  echo ""
  echo "List Managed Instances:"
  echo "  ${out_list_cmd}"
  echo ""
  echo "Check Runner & MIG Status (zero SSH):"
  echo "  ./development/scripts/setup.sh --provider=gcp --status"
  echo ""
  echo "Sync development/.env to GitHub Secrets/Variables (if not already synced):"
  echo "  ./development/scripts/setup.sh --provider=gcp"
  echo ""
  gcloud compute instance-groups managed list-instances "${out_mig_name}" \
    --zone="${deployed_zone}" \
    --project="${effective_project}" || true
}

case "$PROVIDER" in
  gcp) run_gcp_terraform ;;
  azure|on-prem) run_azure_or_onprem_terraform ;;
esac
