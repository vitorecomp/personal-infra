#!/usr/bin/env bash
# Unified entrypoint to provision GPU development machines via Terraform.
#
# Routes `--provider=<gcp|azure|on-prem>` to `development/infra/<provider>` and
# runs Terraform using the currently logged-in CLI credentials (and active GCP
# project from `gcloud config` when `--provider=gcp`).
#
# On GCP, provisioning is 100% SSH-free: Terraform creates a Stateless Multi-Zone
# Regional Managed Instance Group (`<name_prefix>-mig`, `target_size = 1`, `ANY`
# target shape, cross-zone Spot failover), a same-region GCS cache bucket
# (`<project>-<name_prefix>-cache-<region>`), and a Secret Manager bootstrap
# secret (`<name_prefix>-runner-bootstrap`). On boot, the GPU VM mounts its
# ephemeral 3 TB Hyperdisk at `/mnt/data`, installs NVIDIA drivers + Podman,
# restores runner credentials, stack config, and Hugging Face weights from GCS,
# self-registers/resumes as a GitHub Actions runner, and auto-resumes any
# previously deployed Podman stack across cross-zone Spot recreations.
#
# Usage:
#   ./development/scripts/deploy.sh --provider=gcp --dry-run
#   ./development/scripts/deploy.sh --provider=gcp
#   ./development/scripts/deploy.sh --provider=gcp --region=europe-west2 --zones=europe-west2-b,europe-west2-c
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
ZONES="${ZONES:-}"
ZONE="${ZONE:-}"
CLI_REGION=""
CLI_ZONES=""
CLI_ZONE=""
CACHE_BUCKET_NAME="${CACHE_BUCKET_NAME:-}"
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
On GCP, deploys a self-registering Stateless Multi-Zone Regional Managed
Instance Group (<prefix>-mig, ANY target shape, cross-zone Spot failover)
backed by an ephemeral 3 TB Hyperdisk, a same-region GCS cache bucket
(<project>-<prefix>-cache-<region>), and GCP Secret Manager
(<prefix>-runner-bootstrap), with zero inbound SSH required.

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
  --zones=Z1,Z2,...             Explicit comma-separated target zones within --region (default: all GPU zones in region)
  --zone=ZONE                   Narrow target zones to a single zone (derives --region from ${ZONE%-*} if unset)
  --cache-bucket=NAME           Optional GCS cache bucket name override (default: <project>-<prefix>-cache-<region>)
  --regions=R1,R2,...           Comma-separated regions to cycle through (each spanning all its GPU-capable zones)
  --cycle-regions               Cycle through all GPU-capable regions (spanning all GPU zones per region)
  --machine-type=TYPE           GPU VM machine type override (default: g4-standard-192)
  --name-prefix=PREFIX          Resource name prefix override (default: dev-gpu)
  --spot                        Provision the GPU VM as a Spot VM with cross-zone failover (default)
  --no-spot, --standard         Provision the GPU VM as a Standard on-demand VM (sets use_spot=false)
  --use-default-vpc             Attach the MIG to the existing 'default' VPC instead of creating a custom VPC
  --no-use-default-vpc          Create and use a dedicated custom VPC (default; alias: --custom-vpc)
  --default-vpc-name=NAME       Existing VPC name when --use-default-vpc is set (default: default)
  --ssh-proxy-cidrs=C1,C2,...   Proxy CIDRs allowed on TCP 22 for optional debugging (default: 35.235.240.0/20)
  --ssh-hostname-template=TPL   Optional SSH relay hostname template ({instance}, {zone}, {project})
  --force-move                  Allow moving to another region even if an active Regional MIG exists in state
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
  # Preview a multi-zone Spot Regional MIG + GCS cache bucket deployment on GCP:
  ./development/scripts/deploy.sh --provider=gcp --dry-run

  # Target specific zones within a region (e.g., europe-west2-b and europe-west2-c):
  ./development/scripts/deploy.sh --provider=gcp --region=europe-west2 --zones=europe-west2-b,europe-west2-c

  # Provision a Standard (on-demand) Regional GPU MIG on the existing 'default' VPC:
  ./development/scripts/deploy.sh --provider=gcp --no-spot --use-default-vpc

  # Cycle across all GPU-capable regions (spanning all GPU zones per region) every 5 minutes:
  ./development/scripts/deploy.sh --provider=gcp --spot --cycle-regions --loop=5

  # Inspect planned Terraform changes or tear down the Regional MIG:
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
    --zones=*) ZONES="${1#*=}"; CLI_ZONES="${1#*=}"; shift ;;
    --zones) require_arg "$1" "${2:-}"; ZONES="$2"; CLI_ZONES="$2"; shift 2 ;;
    --zone=*) ZONE="${1#*=}"; CLI_ZONE="${1#*=}"; shift ;;
    --zone) require_arg "$1" "${2:-}"; ZONE="$2"; CLI_ZONE="$2"; shift 2 ;;
    --cache-bucket=*) CACHE_BUCKET_NAME="${1#*=}"; shift ;;
    --cache-bucket) require_arg "$1" "${2:-}"; CACHE_BUCKET_NAME="$2"; shift 2 ;;
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

tfvars_get_list_csv() {
  local key="$1"
  local file="$INFRA_DIR/terraform.tfvars"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$key" <<'PY'
import re, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    cleaned = "\n".join(line.split("#", 1)[0] for line in fh)
m = re.search(rf'(?m)^\s*{re.escape(key)}\s*=\s*\[([^\]]*)\]', cleaned)
if m:
    items = [s.strip() for s in re.findall(r'"([^"]+)"', m.group(1)) if s.strip()]
    if items:
        print(",".join(items))
PY
}

normalize_zones_csv() {
  local raw="$1"
  [[ -n "$raw" ]] || return 0
  python3 - "$raw" <<'PY'
import sys
seen = []
for part in sys.argv[1].split(","):
    z = part.strip()
    if z and z not in seen:
        seen.append(z)
print(",".join(seen))
PY
}

zones_csv_to_json() {
  local raw="$1"
  [[ -n "$raw" ]] || return 0
  python3 - "$raw" <<'PY'
import json, sys
items = [z.strip() for z in sys.argv[1].split(",") if z.strip()]
if items:
    print(json.dumps(items, separators=(",", ":")))
PY
}

zones_match_region() {
  local zones_csv="$1"
  local region="$2"
  [[ -n "$zones_csv" && -n "$region" ]] || return 1
  python3 - "$zones_csv" "$region" <<'PY'
import sys
zones = [z.strip() for z in sys.argv[1].split(",") if z.strip()]
region = sys.argv[2].strip()
sys.exit(0 if zones and all(z.rsplit("-", 1)[0] == region for z in zones) else 1)
PY
}

compute_cache_bucket_name() {
  local project="$1"
  local prefix="$2"
  local region="$3"
  local override="${4:-}"
  python3 - "$project" "$prefix" "$region" "$override" <<'PY'
import re, sys
project, prefix, region, override = [a.strip() for a in sys.argv[1:5]]
if override:
    print(override.lower())
elif project.startswith("<"):
    print(f"{project}-{prefix}-cache-{region}".lower())
else:
    raw = f"{project}-{prefix}-cache-{region}".lower()
    print(re.sub(r"[^a-z0-9-]", "-", raw)[:63].strip("-"))
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
  local tfvars_project tfvars_region tfvars_zones tfvars_zone tfvars_cache_bucket
  local tfvars_machine tfvars_prefix tfvars_use_spot tfvars_use_default_vpc
  local tfvars_repo tfvars_runner_name tfvars_runner_labels tfvars_runner_user
  tfvars_project="$(tfvars_get_string project_id)"
  tfvars_region="$(tfvars_get_string region)"
  tfvars_zones="$(tfvars_get_list_csv zones)"
  tfvars_zone="$(tfvars_get_string zone)"
  tfvars_cache_bucket="$(tfvars_get_string cache_bucket_name)"
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
  local dotenv_zones dotenv_zone
  dotenv_zones="$(dotenv_get_string ZONES)"
  dotenv_zone="$(dotenv_get_string ZONE)"
  [[ -z "$CACHE_BUCKET_NAME" ]] && CACHE_BUCKET_NAME="$(dotenv_get_string CACHE_BUCKET_NAME)"
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

  # Region & Zones resolution:
  #   - CLI --zones / --zone is authoritative (derives region from first zone if --region is unset).
  #   - Explicit CLI --region ignores conflicting .env/tfvars zones from another region.
  local cli_zones_csv=""
  if [[ -n "$CLI_ZONES" ]]; then
    cli_zones_csv="$(normalize_zones_csv "$CLI_ZONES")"
  elif [[ -n "$CLI_ZONE" ]]; then
    cli_zones_csv="$(normalize_zones_csv "$CLI_ZONE")"
  fi

  local explicit_region="$REGION"
  local default_region="${REGION:-${tfvars_region:-europe-west4}}"
  if [[ -n "$cli_zones_csv" ]]; then
    local first_cli_zone="${cli_zones_csv%%,*}"
    if [[ -z "$CLI_REGION" ]]; then
      default_region="${first_cli_zone%-*}"
      explicit_region="$default_region"
    fi
    if ! zones_match_region "$cli_zones_csv" "$default_region"; then
      echo "[error] Specified zone(s) '${cli_zones_csv}' do not all belong to region '${default_region}'." >&2
      exit 1
    fi
  fi

  local explicit_zones_csv="$cli_zones_csv"
  if [[ -z "$explicit_zones_csv" ]]; then
    local env_zones_raw="${ZONES:-${ZONE:-}}"
    if [[ -n "$env_zones_raw" ]]; then
      local norm_env_zones
      norm_env_zones="$(normalize_zones_csv "$env_zones_raw")"
      if [[ -z "$CLI_REGION" ]] || zones_match_region "$norm_env_zones" "$CLI_REGION"; then
        explicit_zones_csv="$norm_env_zones"
      fi
    else
      local fallback_zones_raw="${dotenv_zones:-${dotenv_zone:-${tfvars_zones:-${tfvars_zone:-}}}}"
      if [[ -n "$fallback_zones_raw" ]]; then
        local norm_fb_zones
        norm_fb_zones="$(normalize_zones_csv "$fallback_zones_raw")"
        if [[ -z "$CLI_REGION" ]] || zones_match_region "$norm_fb_zones" "$CLI_REGION"; then
          explicit_zones_csv="$norm_fb_zones"
        fi
      fi
    fi
    if [[ -n "$explicit_zones_csv" && -z "$explicit_region" && -z "$tfvars_region" ]]; then
      local first_ez="${explicit_zones_csv%%,*}"
      default_region="${first_ez%-*}"
    fi
    if [[ -n "$explicit_zones_csv" ]] && ! zones_match_region "$explicit_zones_csv" "$default_region"; then
      explicit_zones_csv=""
    fi
  fi

  local effective_machine="${MACHINE_TYPE:-${tfvars_machine:-g4-standard-192}}"
  local effective_prefix="${NAME_PREFIX:-${tfvars_prefix:-dev-gpu}}"
  local effective_cache_bucket_override="${CACHE_BUCKET_NAME:-${tfvars_cache_bucket:-}}"
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
print(json.dumps(items, separators=(",", ":")) if items else "")
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
    local target_zones_csv="${2:-}"
    var_args=(
      -input=false
      -var="project_id=${effective_project}"
      -var="region=${target_region}"
      -var="use_spot=${effective_use_spot}"
      -var="enable_public_ingress=false"
      -var="github_repo=${effective_repo}"
      -var="runner_name=${effective_runner_name}"
      -var="runner_labels=${effective_runner_labels}"
      -var="runner_username=${effective_runner_user}"
    )
    if [[ -n "$target_zones_csv" ]]; then
      local zones_json
      zones_json="$(zones_csv_to_json "$target_zones_csv")"
      if [[ -n "$zones_json" ]]; then
        var_args+=(-var="zones=${zones_json}")
      fi
    elif [[ -n "$tfvars_zone" && "${tfvars_zone%-*}" != "$target_region" ]]; then
      # Prevent a stale single-zone entry in terraform.tfvars from conflicting with another region.
      var_args+=(-var="zone=")
    fi
    if [[ -n "$CACHE_BUCKET_NAME" ]]; then
      var_args+=(-var="cache_bucket_name=${CACHE_BUCKET_NAME}")
    fi
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

  local provisioning_desc="SPOT (cross-zone failover via Regional MIG; use_spot=true)"
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
    local dry_run_bucket
    dry_run_bucket="$(compute_cache_bucket_name "$effective_project" "$effective_prefix" "$default_region" "$effective_cache_bucket_override")"
    build_tf_args "$default_region" "$explicit_zones_csv"
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
    echo "[dry-run] Region / Target Zones: $default_region / ${explicit_zones_csv:-all GPU-capable zones in region} (cycle_regions=$CYCLE_REGIONS${REGIONS_LIST:+, regions=$REGIONS_LIST})"
    echo "[dry-run] Provisioning Model:   $provisioning_desc"
    echo "[dry-run] VPC Network:          $vpc_mode_desc"
    echo "[dry-run] Machine / Prefix:     $effective_machine / $effective_prefix"
    echo "[dry-run] Cache Bucket:         gs://${dry_run_bucket}"
    echo "[dry-run] Runner Bootstrap:     Secret Manager (${effective_prefix}-runner-bootstrap -> ${effective_repo}, auth=${runner_auth_desc})"
    echo "[dry-run] Commands:"
    $use_adc || echo "[dry-run]   export GOOGLE_OAUTH_ACCESS_TOKEN=\"\$(gcloud auth print-access-token)\""
    echo "[dry-run]   gcloud services enable compute.googleapis.com secretmanager.googleapis.com iap.googleapis.com oslogin.googleapis.com iam.googleapis.com storage.googleapis.com --project=$effective_project --quiet"
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
        echo "[dry-run]   gcloud compute instance-groups managed list-instances ${effective_prefix}-mig --region=${default_region} --project=${effective_project} --format=json  # poll until RUNNING"
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
          echo "[warn] Failed to mint GitHub runner registration token for ${effective_repo}; continuing (GCS-cached actions-runner credentials will still be reused if present)." >&2
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

  echo "Enabling required GCP APIs (compute, secretmanager, iap, oslogin, iam, storage) in project: ${effective_project}..."
  gcloud services enable \
    compute.googleapis.com \
    secretmanager.googleapis.com \
    iap.googleapis.com \
    oslogin.googleapis.com \
    iam.googleapis.com \
    storage.googleapis.com \
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

  # Inspect current Terraform state for an existing Regional MIG, legacy Zonal MIG,
  # and any legacy 2-VM resources.
  local raw_state_json state_mig_region state_mig_name state_mig_zones tainted_rmig_region
  local legacy_zonal_mig_zone tainted_legacy_zonal_mig_zone
  local legacy_gpu_zone legacy_ctrl_zone legacy_data_zone
  raw_state_json="$("${TF[@]}" state pull 2>/dev/null || true)"
  read -r state_mig_region state_mig_name state_mig_zones tainted_rmig_region \
    legacy_zonal_mig_zone tainted_legacy_zonal_mig_zone \
    legacy_gpu_zone legacy_ctrl_zone legacy_data_zone < <(
    printf '%s' "$raw_state_json" | python3 -c '
import json, sys
default_prefix = sys.argv[1]
try:
    s = json.load(sys.stdin)
except Exception:
    print(f"- {default_prefix}-mig - - - - - - -")
    sys.exit(0)
rmig_region = rmig_zones = tainted_rmig_region = "-"
legacy_zonal_zone = tainted_legacy_zonal_zone = "-"
legacy_gpu_zone = legacy_ctrl_zone = legacy_data_zone = "-"
mig_name = f"{default_prefix}-mig"
for r in s.get("resources", []):
    insts = r.get("instances", [])
    if not insts:
        continue
    inst0 = insts[0]
    attrs = inst0.get("attributes", {})
    rtype, rname = r.get("type"), r.get("name")
    if rtype == "google_compute_region_instance_group_manager" and rname == "gpu":
        reg = attrs.get("region") or "-"
        if attrs.get("name"):
            mig_name = attrs["name"]
        dpz = attrs.get("distribution_policy_zones") or []
        if isinstance(dpz, list):
            clean_dpz = [str(z).strip() for z in dpz if str(z).strip()]
            if clean_dpz:
                rmig_zones = ",".join(clean_dpz)
        if inst0.get("status") == "tainted" or not attrs.get("self_link"):
            tainted_rmig_region = reg
        else:
            rmig_region = reg
    elif rtype == "google_compute_instance_group_manager" and rname == "gpu":
        z = attrs.get("zone") or "-"
        if inst0.get("status") == "tainted" or not attrs.get("self_link"):
            tainted_legacy_zonal_zone = z
        else:
            legacy_zonal_zone = z
    elif rtype == "google_compute_instance" and rname == "gpu_vm":
        legacy_gpu_zone = attrs.get("zone") or "-"
    elif rtype == "google_compute_instance" and rname == "controller":
        legacy_ctrl_zone = attrs.get("zone") or "-"
    elif rtype == "google_compute_disk" and rname == "gpu_data":
        legacy_data_zone = attrs.get("zone") or "-"
print(
    f"{rmig_region} {mig_name} {rmig_zones} {tainted_rmig_region} "
    f"{legacy_zonal_zone} {tainted_legacy_zonal_zone} "
    f"{legacy_gpu_zone} {legacy_ctrl_zone} {legacy_data_zone}"
)
' "$effective_prefix"
  )

  # Clean up any tainted/uncreated MIG state stubs from a failed prior apply so Terraform
  # does not fail refreshing a non-existent MIG or mis-detect it as active.
  if [[ "$ACTION" == "apply" ]]; then
    if [[ "$tainted_rmig_region" != "-" ]]; then
      "${TF[@]}" state rm google_compute_region_instance_group_manager.gpu >/dev/null 2>&1 || true
    fi
    if [[ "$tainted_legacy_zonal_mig_zone" != "-" ]]; then
      "${TF[@]}" state rm google_compute_instance_group_manager.gpu >/dev/null 2>&1 || true
    fi
  fi

  local pinned_plan_region="$default_region"
  local pinned_plan_zones="$explicit_zones_csv"
  if [[ -z "$CLI_REGION" && -z "$cli_zones_csv" ]]; then
    if [[ "$state_mig_region" != "-" ]]; then
      pinned_plan_region="$state_mig_region"
      if [[ -z "$pinned_plan_zones" && "$state_mig_zones" != "-" ]]; then
        pinned_plan_zones="$state_mig_zones"
      fi
    elif [[ "$tainted_rmig_region" != "-" ]]; then
      pinned_plan_region="$tainted_rmig_region"
    elif [[ "$legacy_zonal_mig_zone" != "-" ]]; then
      pinned_plan_region="${legacy_zonal_mig_zone%-*}"
    elif [[ "$legacy_gpu_zone" != "-" ]]; then
      pinned_plan_region="${legacy_gpu_zone%-*}"
    elif [[ "$legacy_ctrl_zone" != "-" ]]; then
      pinned_plan_region="${legacy_ctrl_zone%-*}"
    fi
  fi

  if [[ "$ACTION" == "plan" ]]; then
    prepare_runner_bootstrap_auth
    refresh_gcp_credentials
    build_tf_args "$pinned_plan_region" "$pinned_plan_zones"
    "${TF[@]}" plan "${var_args[@]}"
    return 0
  fi

  if [[ "$ACTION" == "destroy" ]]; then
    refresh_gcp_credentials
    build_tf_args "$pinned_plan_region" "$pinned_plan_zones"
    "${TF[@]}" destroy "${apply_args[@]}"
    return 0
  fi

  prepare_runner_bootstrap_auth

  if [[ "$legacy_gpu_zone" != "-" || "$legacy_ctrl_zone" != "-" || "$legacy_data_zone" != "-" ]]; then
    echo "Detected legacy standalone 2-VM resources in Terraform state (controller=${legacy_ctrl_zone}, gpu_vm=${legacy_gpu_zone}, data=${legacy_data_zone}); releasing them before creating Regional MIG so GPU/disk quota is free..."
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
      build_tf_args "$pinned_plan_region" ""
      "${TF[@]}" destroy -auto-approve "${var_args[@]}" "${legacy_targets[@]}" || true
    fi
  fi

  if [[ "$legacy_zonal_mig_zone" != "-" ]]; then
    echo "Detected legacy zonal MIG (google_compute_instance_group_manager.gpu in ${legacy_zonal_mig_zone}) in Terraform state; releasing it first so GPU quota and MIG name '${effective_prefix}-mig' are freed before creating the Regional MIG..."
    refresh_gcp_credentials
    build_tf_args "${legacy_zonal_mig_zone%-*}" ""
    "${TF[@]}" destroy -auto-approve "${var_args[@]}" \
      -target=google_compute_instance_group_manager.gpu || true
  fi

  # Check whether an existing Regional MIG in state currently has a RUNNING instance.
  local state_mig_running="false"
  if [[ "$state_mig_region" != "-" ]]; then
    local state_mig_list_json
    state_mig_list_json="$(gcloud compute instance-groups managed list-instances "$state_mig_name" \
      --region="$state_mig_region" \
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

  # Build region-level candidate list (`region:z1,z2,...`).
  local candidate_regions=()
  if [[ -n "$cli_zones_csv" ]]; then
    candidate_regions=("${default_region}:${cli_zones_csv}")
  else
    echo "Discovering zones offering ${effective_machine} across regions in project ${effective_project}..."
    local raw_machine_zones
    raw_machine_zones="$(gcloud compute machine-types list \
      --project="${effective_project}" \
      --filter="name=${effective_machine}" \
      --format="value(zone)" 2>/dev/null || true)"

    if [[ "$state_mig_region" != "-" && "$FORCE_MOVE" != "true" ]] && \
       { [[ "$state_mig_running" == "true" ]] || [[ "$CYCLE_REGIONS" != "true" && -z "$REGIONS_LIST" ]]; }; then
      local pinned_zones=""
      if [[ -n "$explicit_zones_csv" ]] && zones_match_region "$explicit_zones_csv" "$state_mig_region"; then
        pinned_zones="$explicit_zones_csv"
      else
        pinned_zones="$(
          python3 - "$state_mig_region" "$state_mig_zones" "$raw_machine_zones" <<'PY'
import sys
reg, state_zones, raw = sys.argv[1], sys.argv[2], sys.argv[3]
discovered = sorted({z.strip() for z in raw.splitlines() if z.strip() and z.strip().rsplit("-", 1)[0] == reg})
if discovered:
    print(",".join(discovered))
elif state_zones != "-":
    print(state_zones)
PY
        )"
      fi
      echo "Pinning deployment to existing Regional MIG '${state_mig_name}' in state: ${state_mig_region} (zones=${pinned_zones:-all}, running=${state_mig_running})"
      candidate_regions=("${state_mig_region}:${pinned_zones}")
    else
      local preferred_state_region="$state_mig_region"
      if [[ "$preferred_state_region" == "-" ]]; then
        preferred_state_region="$tainted_rmig_region"
      fi
      if [[ "$preferred_state_region" == "-" && "$legacy_zonal_mig_zone" != "-" ]]; then
        preferred_state_region="${legacy_zonal_mig_zone%-*}"
      fi
      if [[ "$preferred_state_region" == "-" && "$legacy_data_zone" != "-" ]]; then
        preferred_state_region="${legacy_data_zone%-*}"
      fi
      if [[ -z "$explicit_region" && -z "$cli_zones_csv" && "$preferred_state_region" != "-" ]]; then
        default_region="$preferred_state_region"
      fi

      mapfile -t candidate_regions < <(
        python3 - "$default_region" "$REGIONS_LIST" "$CYCLE_REGIONS" "$explicit_zones_csv" "$raw_machine_zones" <<'PY'
import sys

default_region = sys.argv[1]
regions_csv = sys.argv[2]
cycle_all = sys.argv[3] == "true"
explicit_zones_csv = sys.argv[4]
all_zones = sorted({z.strip() for z in sys.argv[5].splitlines() if z.strip()})

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
    target_regions = []
    for r in regions_csv.split(","):
        r = r.strip()
        if r and r not in target_regions:
            target_regions.append(r)
elif cycle_all:
    target_regions = []
    for r in preferred_order + sorted(by_region.keys()):
        if r in by_region and r not in target_regions:
            target_regions.append(r)
    if not target_regions and not all_zones:
        target_regions = [default_region]
else:
    target_regions = [default_region]

explicit_zones = [z.strip() for z in explicit_zones_csv.split(",") if z.strip()]

for r in target_regions:
    if not regions_csv and not cycle_all and explicit_zones and all(z.rsplit("-", 1)[0] == r for z in explicit_zones):
        print(f"{r}:{','.join(explicit_zones)}")
        continue
    zones = by_region.get(r, [])
    if zones:
        print(f"{r}:{','.join(zones)}")
    elif not all_zones:
        # Machine-type zone discovery returned empty (e.g. transient API hiccup); let GCE span all zones in region.
        print(f"{r}:")
PY
      )
    fi
  fi

  if [[ ${#candidate_regions[@]} -eq 0 ]]; then
    echo "[error] No valid GPU-capable zones found for machine type ${effective_machine} in requested region(s)." >&2
    exit 1
  fi

  echo "Candidate region order (${#candidate_regions[@]}): ${candidate_regions[*]}"

  has_more_candidates() {
    local cur_idx="$1"
    (( cur_idx + 1 < ${#candidate_regions[@]} ))
  }

  destroy_mig_in_region() {
    local target_region="$1"
    local target_zones_csv="${2:-}"
    refresh_gcp_credentials
    build_tf_args "$target_region" "$target_zones_csv"
    "${TF[@]}" destroy -auto-approve "${var_args[@]}" \
      -target=google_compute_region_instance_group_manager.gpu \
      -target=google_compute_instance_template.gpu || true
    # Best-effort cleanup of an empty probe cache bucket when moving off a quota/exhausted region
    # (non-empty cache buckets remain protected by force_destroy=false).
    "${TF[@]}" destroy -auto-approve "${var_args[@]}" \
      -target=google_storage_bucket.gpu_cache || true
  }

  classify_mig_instances_json() {
    python3 -c '
import json, re, sys

raw = sys.stdin.read().strip()
if not raw:
    print("WAITING\t-\t-\t-\tno instances reported yet")
    sys.exit(0)
try:
    items = json.loads(raw)
except Exception as exc:
    msg = " ".join(str(exc).split())
    print(f"WAITING\t-\t-\t-\tinvalid json: {msg}")
    sys.exit(0)
if not isinstance(items, list) or not items:
    print("WAITING\t-\t-\t-\tmig creating instance")
    sys.exit(0)

entry = items[0] if isinstance(items[0], dict) else {}
inst_url = entry.get("instance") or ""
inst_name = inst_url.rsplit("/", 1)[-1] if inst_url else "-"
zm = re.search(r"/zones/([^/]+)/instances/", inst_url)
inst_zone = zm.group(1) if zm else "-"
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
    print(f"RUNNING\t{inst_name}\t{inst_zone}\t{inst_status}\taction={action_label}")
    sys.exit(0)
if inst_status in ("PROVISIONING", "STAGING"):
    print(f"BOOTING\t{inst_name}\t{inst_zone}\t{inst_status}\taction={action_label}")
    sys.exit(0)
if combined_err:
    if re.search(r"QUOTA_EXCEEDED|Quota\b.*\bexceeded", combined_err, re.IGNORECASE):
        print(f"QUOTA\t{inst_name}\t{inst_zone}\t{status_label}\t{combined_err}")
        sys.exit(0)
    if re.search(r"ZONE_RESOURCE_POOL_EXHAUSTED|RESOURCE_POOL_EXHAUSTED|does not have enough resources|stockout|preempted", combined_err, re.IGNORECASE):
        print(f"EXHAUSTED\t{inst_name}\t{inst_zone}\t{status_label}\t{combined_err}")
        sys.exit(0)
    print(f"ERROR\t{inst_name}\t{inst_zone}\t{status_label}\t{combined_err}")
    sys.exit(0)

print(f"WAITING\t{inst_name}\t{inst_zone}\t{status_label}\taction={action_label}")
'
  }

  local deployed_region=""
  local deployed_zones_csv=""
  local deployed_active_zone=""
  local mig_instance_state="UNKNOWN"
  local exhausted_target=""
  local current_state_region="$state_mig_region"
  local current_state_zones="$state_mig_zones"
  [[ "$current_state_zones" == "-" ]] && current_state_zones=""
  local log_file
  log_file="$(mktemp)"
  trap 'rm -f "${log_file:-}"' EXIT

  apply_full_stack() {
    local target_region="$1"
    local target_zones_csv="${2:-}"
    refresh_gcp_credentials
    build_tf_args "$target_region" "$target_zones_csv"
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

  for idx in "${!candidate_regions[@]}"; do
    local target="${candidate_regions[$idx]}"
    local cand_region="${target%%:*}"
    local cand_zones_csv="${target#*:}"

    # When moving an existing Regional MIG to a different region, tear down the old MIG and
    # template first so regional subnetwork replacement never hits a dependency cycle.
    if [[ "$current_state_region" != "-" && "$current_state_region" != "$cand_region" ]]; then
      echo "Releasing previous Regional MIG in ${current_state_region} before moving to ${cand_region}..."
      destroy_mig_in_region "$current_state_region" "$current_state_zones"
      current_state_region="-"
      current_state_zones=""
    fi

    echo "Trying region ${cand_region} (zones=${cand_zones_csv:-all}) ($((idx + 1))/${#candidate_regions[@]})..."
    set +e
    apply_full_stack "$cand_region" "$cand_zones_csv"
    local apply_status=$?
    set -e

    if [[ $apply_status -ne 0 ]]; then
      if grep -Eqi "QUOTA_EXCEEDED|Quota .* exceeded" "$log_file"; then
        echo "Region ${cand_region} hit quota limit during apply; trying next region..."
        destroy_mig_in_region "$cand_region" "$cand_zones_csv"
        current_state_region="-"
        current_state_zones=""
        continue
      fi
      if grep -Eqi "ZONE_RESOURCE_POOL_EXHAUSTED|RESOURCE_POOL_EXHAUSTED|does not have enough resources|stockout" "$log_file"; then
        echo "Region ${cand_region} reported capacity exhaustion during apply; trying next candidate..."
        exhausted_target="${cand_region}:${cand_zones_csv}"
        destroy_mig_in_region "$cand_region" "$cand_zones_csv"
        current_state_region="-"
        current_state_zones=""
        continue
      fi
      exit "$apply_status"
    fi

    current_state_region="$cand_region"
    current_state_zones="$cand_zones_csv"
    local mig_name
    mig_name="$("${TF[@]}" output -raw mig_name 2>/dev/null || echo "${effective_prefix}-mig")"

    echo "Polling Regional MIG '${mig_name}' in ${cand_region} (zones=${cand_zones_csv:-all}) for RUNNING instance (up to 90s)..."
    local mig_result="TIMEOUT"
    local last_inst_name="-"
    local last_inst_zone="-"
    local last_inst_status="NONE"
    local last_detail=""
    local prev_poll_summary=""
    local exhausted_streak=0
    local exhausted_limit=1
    if [[ -z "$cand_zones_csv" || "$cand_zones_csv" == *,* ]]; then
      # Give GCE's multi-zone Regional MIG ~20s to fail over across zones within the region.
      exhausted_limit=4
    fi
    local poll_attempt

    for poll_attempt in $(seq 1 18); do
      local list_json poll_state inst_name inst_zone inst_status detail_msg
      list_json="$(gcloud compute instance-groups managed list-instances "$mig_name" \
        --region="$cand_region" \
        --project="$effective_project" \
        --format=json 2>/dev/null || true)"
      IFS=$'\t' read -r poll_state inst_name inst_zone inst_status detail_msg < <(
        printf '%s' "$list_json" | classify_mig_instances_json
      )
      last_inst_name="$inst_name"
      last_inst_zone="$inst_zone"
      last_inst_status="$inst_status"
      last_detail="$detail_msg"

      local poll_summary="${poll_state}:${inst_name}:${inst_zone}:${inst_status}:${detail_msg}"
      if [[ "$poll_summary" != "$prev_poll_summary" ]]; then
        echo "  [poll ${poll_attempt}/18] instance=${inst_name} zone=${inst_zone} status=${inst_status} state=${poll_state} (${detail_msg})"
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
          exhausted_streak=$(( exhausted_streak + 1 ))
          if (( exhausted_streak >= exhausted_limit || poll_attempt == 18 )); then
            mig_result="EXHAUSTED"
            break
          fi
          sleep 5
          ;;
        BOOTING)
          exhausted_streak=0
          if [[ "$poll_attempt" -eq 18 ]]; then
            mig_result="BOOTING"
          else
            sleep 5
          fi
          ;;
        ERROR)
          exhausted_streak=0
          if [[ "$poll_attempt" -eq 18 ]]; then
            mig_result="ERROR"
          else
            sleep 5
          fi
          ;;
        *)
          exhausted_streak=0
          if [[ "$poll_attempt" -lt 18 ]]; then
            sleep 5
          fi
          ;;
      esac
    done

    case "$mig_result" in
      RUNNING)
        echo "Managed GPU instance '${last_inst_name}' is RUNNING in zone ${last_inst_zone} (region ${cand_region})."
        deployed_region="$cand_region"
        deployed_zones_csv="$cand_zones_csv"
        [[ "$last_inst_zone" != "-" ]] && deployed_active_zone="$last_inst_zone"
        mig_instance_state="RUNNING"
        break
        ;;
      BOOTING)
        echo "Managed GPU instance '${last_inst_name}' is allocated and booting (${last_inst_status}) in zone ${last_inst_zone} (region ${cand_region})."
        deployed_region="$cand_region"
        deployed_zones_csv="$cand_zones_csv"
        [[ "$last_inst_zone" != "-" ]] && deployed_active_zone="$last_inst_zone"
        mig_instance_state="$last_inst_status"
        break
        ;;
      QUOTA)
        echo "Region ${cand_region} hit quota limit (${last_detail}); trying next region..."
        destroy_mig_in_region "$cand_region" "$cand_zones_csv"
        current_state_region="-"
        current_state_zones=""
        continue
        ;;
      EXHAUSTED|TIMEOUT)
        exhausted_target="${cand_region}:${cand_zones_csv}"
        if has_more_candidates "$idx" || [[ "$STAGE_ON_EXHAUSTION" != "true" ]]; then
          echo "Region ${cand_region} (zones=${cand_zones_csv:-all}) has no immediate GPU capacity (${last_detail}); destroying Regional MIG before trying next candidate..."
          destroy_mig_in_region "$cand_region" "$cand_zones_csv"
          current_state_region="-"
          current_state_zones=""
          continue
        else
          echo "Region ${cand_region} (zones=${cand_zones_csv:-all}) has no immediate GPU capacity (${last_detail}); leaving Regional MIG '${mig_name}' active to auto-allocate across zones once capacity opens."
          deployed_region="$cand_region"
          deployed_zones_csv="$cand_zones_csv"
          mig_instance_state="PENDING_CAPACITY"
          break
        fi
        ;;
      ERROR)
        echo "[error] Regional MIG '${mig_name}' in ${cand_region} reported an error: ${last_detail}" >&2
        if has_more_candidates "$idx"; then
          destroy_mig_in_region "$cand_region" "$cand_zones_csv"
          current_state_region="-"
          current_state_zones=""
          continue
        fi
        exit 1
        ;;
    esac
  done

  # If the final candidates hit quota after an earlier quota-valid region hit stockout,
  # stage the Regional MIG in the quota-valid region when STAGE_ON_EXHAUSTION=true.
  if [[ -z "$deployed_region" && -n "$exhausted_target" && "$STAGE_ON_EXHAUSTION" == "true" ]]; then
    local fb_region="${exhausted_target%%:*}"
    local fb_zones="${exhausted_target#*:}"
    echo "All candidate regions out of immediate GPU capacity; keeping Regional MIG active in ${fb_region} (zones=${fb_zones:-all}) to auto-allocate as soon as capacity opens..."
    apply_full_stack "$fb_region" "$fb_zones"
    deployed_region="$fb_region"
    deployed_zones_csv="$fb_zones"
    mig_instance_state="PENDING_CAPACITY"
  fi

  if [[ -z "$deployed_region" ]]; then
    echo "[error] Failed to allocate GPU capacity across candidate regions: ${candidate_regions[*]}" >&2
    exit 1
  fi

  local out_mig_name out_vpc out_secret out_runner_name out_use_spot out_cache_bucket_url out_list_cmd
  out_mig_name="$("${TF[@]}" output -raw mig_name 2>/dev/null || echo "${effective_prefix}-mig")"
  out_vpc="$("${TF[@]}" output -raw vpc_network 2>/dev/null || echo "${vpc_mode_desc}")"
  out_secret="$("${TF[@]}" output -raw runner_secret_id 2>/dev/null || echo "${effective_prefix}-runner-bootstrap")"
  out_runner_name="$("${TF[@]}" output -raw runner_name 2>/dev/null || echo "${effective_runner_name}")"
  out_use_spot="$("${TF[@]}" output -raw use_spot 2>/dev/null || echo "${effective_use_spot}")"
  out_cache_bucket_url="$("${TF[@]}" output -raw cache_bucket_url 2>/dev/null || true)"
  if [[ -z "$out_cache_bucket_url" ]]; then
    local out_cache_bucket_name
    out_cache_bucket_name="$("${TF[@]}" output -raw cache_bucket_name 2>/dev/null || compute_cache_bucket_name "$effective_project" "$effective_prefix" "$deployed_region" "$effective_cache_bucket_override")"
    out_cache_bucket_url="gs://${out_cache_bucket_name}"
  fi
  out_list_cmd="$("${TF[@]}" output -raw list_instances_command 2>/dev/null || echo "gcloud compute instance-groups managed list-instances ${out_mig_name} --region=${deployed_region} --project=${effective_project}")"

  local final_model_desc="SPOT (cross-zone failover via Regional MIG)"
  if [[ "${out_use_spot,,}" == "false" ]]; then
    final_model_desc="STANDARD (on-demand)"
  fi

  local target_zones_display="${deployed_zones_csv:-all zones in ${deployed_region}}"
  if [[ -n "$deployed_active_zone" ]]; then
    target_zones_display="${target_zones_display} (active: ${deployed_active_zone})"
  fi

  echo ""
  echo "================================================================"
  echo "Stateless Multi-Zone Regional GPU MIG deployed successfully (GCP)"
  echo "================================================================"
  echo "Project:              ${effective_project}"
  echo "Region:               ${deployed_region}"
  echo "Target Zones:         ${target_zones_display}"
  echo "Provisioning Model:   ${final_model_desc}"
  echo "Machine Type:         ${effective_machine}"
  echo "VPC Network:          ${out_vpc}"
  echo "MIG Name:             ${out_mig_name} (state=${mig_instance_state})"
  echo "Runner Secret:        ${out_secret} -> ${effective_repo} (runner=${out_runner_name})"
  echo "Cache Bucket:         ${out_cache_bucket_url}"
  if [[ "$mig_instance_state" == "PENDING_CAPACITY" ]]; then
    echo ""
    echo "Note: The Regional MIG is active in ${deployed_region} (zones=${deployed_zones_csv:-all}) and"
    echo "      will automatically allocate the GPU VM in any available zone, restore cached"
    echo "      state from ${out_cache_bucket_url}, and register the runner as soon as capacity opens."
  fi
  echo ""
  echo "List Managed Instances:"
  echo "  ${out_list_cmd}"
  echo ""
  echo "Check Runner & Regional MIG Status (zero SSH):"
  echo "  ./development/scripts/setup.sh --provider=gcp --status"
  echo ""
  echo "Sync development/.env to GitHub Secrets/Variables (if not already synced):"
  echo "  ./development/scripts/setup.sh --provider=gcp"
  echo ""
  gcloud compute instance-groups managed list-instances "${out_mig_name}" \
    --region="${deployed_region}" \
    --project="${effective_project}" || true
}

case "$PROVIDER" in
  gcp) run_gcp_terraform ;;
  azure|on-prem) run_azure_or_onprem_terraform ;;
esac
