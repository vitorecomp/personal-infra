#!/usr/bin/env bash
# Unified entrypoint to provision GPU development machines via Terraform.
#
# Routes `--provider=<gcp|azure|on-prem>` to `development/infra/<provider>` and
# runs Terraform using the currently logged-in CLI credentials (and active GCP
# project from `gcloud config` when `--provider=gcp`).
#
# On GCP, public internet ingress is disabled and SSH access uses
# `gcloud compute ssh --tunnel-through-iap`.
#
# Usage:
#   ./development/scripts/deploy.sh --provider=gcp
#   ./development/scripts/deploy.sh --provider=gcp --dry-run
#   ./development/scripts/deploy.sh --provider=gcp --plan
#   ./development/scripts/deploy.sh --provider=gcp --cycle-regions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEV_ROOT/.." && pwd)"

PROVIDER="${PROVIDER:-}"
ACTION="apply"
DRY_RUN=false
USE_ADC=false
AUTO_APPROVE="${AUTO_APPROVE:-true}"

# Optional overrides (defaults come from logged-in CLI config / terraform.tfvars)
PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-}"
ZONE="${ZONE:-}"
REGIONS_LIST="${REGIONS:-}"
CYCLE_REGIONS="${CYCLE_REGIONS:-false}"
FORCE_MOVE="${FORCE_MOVE:-false}"
STAGE_ON_EXHAUSTION="${STAGE_ON_EXHAUSTION:-true}"
MACHINE_TYPE="${MACHINE_TYPE:-}"
NAME_PREFIX="${NAME_PREFIX:-}"

usage() {
  cat <<'EOF'
Usage: ./development/scripts/deploy.sh --provider=<gcp|azure|on-prem> [options]

Required:
  --provider=PROVIDER           Target infrastructure provider: gcp, azure, or on-prem

Actions:
  --apply                       Initialize and apply Terraform (default)
  --plan                        Initialize and run terraform plan only
  --validate                    Initialize (-backend=false) and validate Terraform
  --destroy                     Destroy Terraform-managed infrastructure
  --dry-run                     Print resolved credentials/project and commands without executing

GCP / Terraform Options:
  --project=PROJECT_ID          Override active gcloud project (defaults to `gcloud config get-value project`)
  --adc                         Use Application Default Credentials instead of logged-in `gcloud` token
  --region=REGION               Target region (default: europe-west4, or terraform.tfvars)
  --zone=ZONE                   Target zone (default: europe-west4-a, or all GPU zones in region on apply)
  --regions=R1,R2,...           Comma-separated regions to cycle through for Spot capacity
  --cycle-regions               Cycle through all GPU-capable regions until Spot capacity is found
  --machine-type=TYPE           GPU VM machine type override (default: g4-standard-192)
  --name-prefix=PREFIX          Resource name prefix override (default: dev-gpu)
  --force-move                  Allow moving to another region/zone even if an instance exists in state
  --no-stage-terminated         Exit 1 instead of staging a TERMINATED Spot VM when out of stock
  --auto-approve                Pass -auto-approve to terraform apply/destroy (default)
  --no-auto-approve             Require interactive approval on terraform apply/destroy
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
    --apply) ACTION="apply"; shift ;;
    --plan) ACTION="plan"; shift ;;
    --validate) ACTION="validate"; shift ;;
    --destroy) ACTION="destroy"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --adc) USE_ADC=true; shift ;;
    --project=*) PROJECT_ID="${1#*=}"; shift ;;
    --project) require_arg "$1" "${2:-}"; PROJECT_ID="$2"; shift 2 ;;
    --region=*) REGION="${1#*=}"; shift ;;
    --region) require_arg "$1" "${2:-}"; REGION="$2"; shift 2 ;;
    --zone=*) ZONE="${1#*=}"; shift ;;
    --zone) require_arg "$1" "${2:-}"; ZONE="$2"; shift 2 ;;
    --regions=*) REGIONS_LIST="${1#*=}"; shift ;;
    --regions) require_arg "$1" "${2:-}"; REGIONS_LIST="$2"; shift 2 ;;
    --cycle-regions) CYCLE_REGIONS="true"; shift ;;
    --machine-type=*) MACHINE_TYPE="${1#*=}"; shift ;;
    --machine-type) require_arg "$1" "${2:-}"; MACHINE_TYPE="$2"; shift 2 ;;
    --name-prefix=*) NAME_PREFIX="${1#*=}"; shift ;;
    --name-prefix) require_arg "$1" "${2:-}"; NAME_PREFIX="$2"; shift 2 ;;
    --force-move) FORCE_MOVE="true"; shift ;;
    --no-stage-terminated) STAGE_ON_EXHAUSTION="false"; shift ;;
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
  local tfvars_project tfvars_region tfvars_zone tfvars_machine tfvars_prefix
  tfvars_project="$(tfvars_get_string project_id)"
  tfvars_region="$(tfvars_get_string region)"
  tfvars_zone="$(tfvars_get_string zone)"
  tfvars_machine="$(tfvars_get_string machine_type)"
  tfvars_prefix="$(tfvars_get_string name_prefix)"

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

  local oslogin_user="${OSLOGIN_USER:-$logged_account}"
  if [[ -z "$oslogin_user" && "$USE_ADC" == "false" ]] && ! $DRY_RUN; then
    echo "[error] No logged-in gcloud account found. Run 'gcloud auth login' first (or pass --adc)." >&2
    exit 1
  fi

  refresh_gcp_credentials() {
    if $USE_ADC; then
      return 0
    fi
    if ! GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null)" || [[ -z "$GOOGLE_OAUTH_ACCESS_TOKEN" ]]; then
      echo "[error] Failed to obtain access token from logged-in gcloud session. Run 'gcloud auth login' (or pass --adc)." >&2
      exit 1
    fi
    export GOOGLE_OAUTH_ACCESS_TOKEN
  }

  local explicit_region="$REGION"
  local default_region="${REGION:-${tfvars_region:-europe-west4}}"
  local explicit_zone="${ZONE:-${tfvars_zone:-}}"
  if [[ -n "$explicit_zone" && -z "$explicit_region" && -z "$tfvars_region" ]]; then
    default_region="${explicit_zone%-*}"
  fi
  local default_zone="${explicit_zone:-${default_region}-a}"

  local effective_machine="${MACHINE_TYPE:-${tfvars_machine:-g4-standard-192}}"
  local effective_prefix="${NAME_PREFIX:-${tfvars_prefix:-dev-gpu}}"
  local tf_workspace="${TF_WORKSPACE:-$effective_project}"

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
      -var="enable_public_ingress=false"
    )
    if [[ -n "$MACHINE_TYPE" ]]; then
      var_args+=(-var="machine_type=${MACHINE_TYPE}")
    fi
    if [[ -n "$NAME_PREFIX" ]]; then
      var_args+=(-var="name_prefix=${NAME_PREFIX}")
    fi
    if [[ -n "$oslogin_user" ]]; then
      var_args+=(-var="oslogin_user=${oslogin_user}")
    fi

    apply_args=("${var_args[@]}")
    if [[ "$AUTO_APPROVE" == "true" ]]; then
      apply_args+=(-auto-approve)
    fi
  }

  if $DRY_RUN; then
    build_tf_args "$default_region" "$default_zone"
    echo "[dry-run] Provider:             gcp ($INFRA_DIR)"
    echo "[dry-run] Action:               $ACTION"
    if $USE_ADC; then
      echo "[dry-run] Credentials:          Application Default Credentials (--adc)"
    else
      echo "[dry-run] Credentials:          logged-in gcloud account (${oslogin_user:-<gcloud-active-account>})"
    fi
    echo "[dry-run] Project / Workspace:  $effective_project / $tf_workspace"
    echo "[dry-run] Region / Zone:        $default_region / $default_zone (cycle_regions=$CYCLE_REGIONS${REGIONS_LIST:+, regions=$REGIONS_LIST})"
    echo "[dry-run] Machine / Prefix:     $effective_machine / $effective_prefix"
    echo "[dry-run] Ingress / SSH:        public ingress disabled; SSH via 'gcloud compute ssh --tunnel-through-iap'"
    echo "[dry-run] Commands:"
    $USE_ADC || echo "[dry-run]   export GOOGLE_OAUTH_ACCESS_TOKEN=\"\$(gcloud auth print-access-token)\""
    echo "[dry-run]   gcloud services enable compute.googleapis.com iap.googleapis.com oslogin.googleapis.com iam.googleapis.com --project=$effective_project --quiet"
    echo "[dry-run]   ${TF[*]} init -input=false"
    echo "[dry-run]   ${TF[*]} workspace select -or-create $tf_workspace"
    case "$ACTION" in
      plan) echo "[dry-run]   ${TF[*]} plan ${var_args[*]}" ;;
      destroy) echo "[dry-run]   ${TF[*]} destroy ${apply_args[*]}" ;;
      apply)
        echo "[dry-run]   ${TF[*]} apply ${apply_args[*]}"
        echo "[dry-run]   export ssh_private_key -> $INFRA_DIR/ssh-key (0600) and ssh_public_key -> $INFRA_DIR/ssh-key.pub"
        ;;
    esac
    return 0
  fi

  if ! command -v gcloud >/dev/null 2>&1; then
    echo "[error] gcloud CLI is required for --provider=gcp." >&2
    exit 1
  fi

  refresh_gcp_credentials
  echo "Using logged-in GCP credentials (${oslogin_user:-ADC}) and project: ${effective_project}"
  echo "Public ingress disabled; SSH access configured via gcloud IAP tunnel."

  echo "Enabling required GCP APIs (compute, iap, oslogin, iam) in project: ${effective_project}..."
  gcloud services enable compute.googleapis.com iap.googleapis.com oslogin.googleapis.com iam.googleapis.com \
    --project="${effective_project}" \
    --quiet

  echo "Initializing Terraform in ${INFRA_DIR}..."
  "${TF[@]}" init -input=false >/dev/null
  "${TF[@]}" workspace select -or-create "${tf_workspace}" >/dev/null

  # Inspect current Terraform state so existing deployments stay pinned unless moving/cycling.
  local state_gpu_zone state_gpu_status state_ctrl_zone state_data_zone expected_gpu_name
  read -r state_gpu_zone state_gpu_status state_ctrl_zone state_data_zone expected_gpu_name < <(
    "${TF[@]}" state pull 2>/dev/null | python3 -c '
import json, sys
default_prefix = sys.argv[1]
try:
    s = json.load(sys.stdin)
except Exception:
    print(f"- - - - {default_prefix}-vm")
    sys.exit(0)
gpu_zone = gpu_status = ctrl_zone = data_zone = "-"
prefix = default_prefix
for r in s.get("resources", []):
    insts = r.get("instances", [])
    if not insts:
        continue
    attrs = insts[0].get("attributes", {})
    rtype, rname = r.get("type"), r.get("name")
    if rtype == "google_compute_instance" and rname == "gpu_vm":
        gpu_zone = attrs.get("zone") or "-"
        gpu_status = attrs.get("current_status") or "-"
        if attrs.get("name"):
            prefix = attrs["name"].removesuffix("-vm")
    elif rtype == "google_compute_instance" and rname == "controller":
        ctrl_zone = attrs.get("zone") or "-"
    elif rtype == "google_compute_disk" and rname == "gpu_data":
        data_zone = attrs.get("zone") or "-"
        if attrs.get("name"):
            prefix = attrs["name"].removesuffix("-data")
print(f"{gpu_zone} {gpu_status} {ctrl_zone} {data_zone} {prefix}-vm")
' "$effective_prefix"
  )

  local pinned_plan_region="$default_region"
  local pinned_plan_zone="$default_zone"
  if [[ -z "$ZONE" && "$state_gpu_zone" != "-" ]]; then
    pinned_plan_zone="$state_gpu_zone"
    [[ -z "$explicit_region" ]] && pinned_plan_region="${state_gpu_zone%-*}"
  elif [[ -z "$ZONE" && "$state_ctrl_zone" != "-" ]]; then
    pinned_plan_zone="$state_ctrl_zone"
    [[ -z "$explicit_region" ]] && pinned_plan_region="${state_ctrl_zone%-*}"
  fi

  if [[ "$ACTION" == "plan" ]]; then
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

  local candidate_targets=()
  if [[ -n "$ZONE" ]]; then
    candidate_targets=("${ZONE%-*}:${ZONE}")
  elif [[ "$state_gpu_zone" != "-" && "$FORCE_MOVE" != "true" ]] && \
       { [[ "$state_gpu_status" == "RUNNING" ]] || [[ "$CYCLE_REGIONS" != "true" && -z "$REGIONS_LIST" ]]; }; then
    local pinned_region="${state_gpu_zone%-*}"
    echo "Pinning deployment to existing GPU VM in state: ${pinned_region} / ${state_gpu_zone} (status=${state_gpu_status})"
    candidate_targets=("${pinned_region}:${state_gpu_zone}")
  elif [[ "$CYCLE_REGIONS" != "true" && -z "$REGIONS_LIST" && -n "$explicit_zone" ]]; then
    candidate_targets=("${default_region}:${explicit_zone}")
  else
    if [[ "$state_gpu_zone" != "-" ]]; then
      local old_r="${state_gpu_zone%-*}"
      echo "Releasing non-running GPU VM in ${state_gpu_zone} before cycling regions..."
      refresh_gcp_credentials
      build_tf_args "$old_r" "$state_gpu_zone"
      "${TF[@]}" destroy -auto-approve "${var_args[@]}" -target=google_compute_instance.gpu_vm || true
      state_gpu_zone="-"
    fi

    echo "Discovering zones offering ${effective_machine} in project ${effective_project}..."
    if [[ -z "$explicit_region" && -z "$ZONE" && "$state_data_zone" != "-" ]]; then
      default_region="${state_data_zone%-*}"
    fi
    local all_machine_zones
    all_machine_zones="$(gcloud compute machine-types list \
      --project="${effective_project}" \
      --filter="name=${effective_machine}" \
      --format="value(zone)" 2>/dev/null | sort -u || true)"

    mapfile -t candidate_targets < <(
      python3 - "$default_region" "$REGIONS_LIST" "$CYCLE_REGIONS" "$state_data_zone" "$all_machine_zones" <<'PY'
import sys

default_region = sys.argv[1]
regions_csv = sys.argv[2]
cycle_all = sys.argv[3] == "true"
state_data_zone = sys.argv[4]
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
    if state_data_zone != "-" and state_data_zone in zones:
        zones.remove(state_data_zone)
        zones.insert(0, state_data_zone)
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

  if [[ "$state_gpu_zone" == "-" ]]; then
    local orphans
    orphans="$(gcloud compute instances list \
      --project="${effective_project}" \
      --filter="name=${expected_gpu_name}" \
      --format="value(name,zone.basename())" 2>/dev/null || true)"
    if [[ -n "$orphans" ]]; then
      while read -r oname ozone; do
        [[ -z "$oname" || -z "$ozone" ]] && continue
        echo "Removing untracked orphan ${oname} in ${ozone} (keeping persistent data disk)..."
        gcloud compute instances delete "$oname" \
          --zone="$ozone" \
          --project="$effective_project" \
          --keep-disks=data \
          --quiet || true
      done <<< "$orphans"
    fi
  fi

  local deployed_region=""
  local deployed_zone=""
  local preempted_target=""
  local skip_region=""
  local last_idx=$(( ${#candidate_targets[@]} - 1 ))
  local log_file
  log_file="$(mktemp)"
  trap 'rm -f "${log_file:-}"' EXIT

  import_and_apply_terminated_gpu() {
    local target_region="$1"
    local target_zone="$2"
    refresh_gcp_credentials
    build_tf_args "$target_region" "$target_zone"
    echo "Importing TERMINATED ${expected_gpu_name} in ${target_zone} and binding watchdog IAM so controller retries start automatically..."
    "${TF[@]}" import "${var_args[@]}" google_compute_instance.gpu_vm \
      "projects/${effective_project}/zones/${target_zone}/instances/${expected_gpu_name}"
    "${TF[@]}" apply "${apply_args[@]}"
    deployed_region="$target_region"
    deployed_zone="$target_zone"
  }

  for idx in "${!candidate_targets[@]}"; do
    local target="${candidate_targets[$idx]}"
    local cand_region="${target%%:*}"
    local cand_zone="${target##*:}"

    if [[ -n "$skip_region" && "$cand_region" == "$skip_region" ]]; then
      continue
    fi

    echo "Trying region ${cand_region} / zone ${cand_zone} ($((idx + 1))/${#candidate_targets[@]})..."
    refresh_gcp_credentials
    build_tf_args "$cand_region" "$cand_zone"

    : > "$log_file"
    set +e
    "${TF[@]}" apply "${apply_args[@]}" 2>&1 | tee "$log_file"
    local status=${PIPESTATUS[0]}
    set -e

    if [[ $status -eq 0 ]]; then
      deployed_region="$cand_region"
      deployed_zone="$cand_zone"
      break
    fi

    if grep -Eqi "QUOTA_EXCEEDED|Quota .* exceeded" "$log_file"; then
      echo "Region ${cand_region} hit quota limit; skipping remaining zones in ${cand_region}..."
      gcloud compute instances delete "$expected_gpu_name" \
        --zone="$cand_zone" --project="$effective_project" --keep-disks=data --quiet 2>/dev/null || true
      skip_region="$cand_region"
      continue
    fi

    if grep -Eqi "ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|stockout|preempted|reach desired status RUNNING|last state: 'TERMINATED'" "$log_file"; then
      local untracked_status
      untracked_status="$(gcloud compute instances describe "$expected_gpu_name" \
        --zone="$cand_zone" --project="$effective_project" --format="value(status)" 2>/dev/null || true)"
      if [[ -n "$untracked_status" && "$state_gpu_zone" == "-" ]]; then
        preempted_target="${cand_region}:${cand_zone}"
        if [[ $idx -lt $last_idx || "$STAGE_ON_EXHAUSTION" != "true" ]]; then
          echo "Zone ${cand_zone} preempted ${expected_gpu_name} during creation (${untracked_status}); deleting untracked VM before trying next candidate..."
          gcloud compute instances delete "$expected_gpu_name" \
            --zone="$cand_zone" --project="$effective_project" --keep-disks=data --quiet || true
          continue
        else
          import_and_apply_terminated_gpu "$cand_region" "$cand_zone"
          break
        fi
      fi

      echo "Zone ${cand_zone} has no free Spot capacity right now; trying next candidate..."
      continue
    fi

    exit $status
  done

  if [[ -z "$deployed_zone" && -n "$preempted_target" && "$state_gpu_zone" == "-" && "$STAGE_ON_EXHAUSTION" == "true" ]]; then
    local fb_region="${preempted_target%%:*}"
    local fb_zone="${preempted_target##*:}"
    echo "All candidate regions/zones out of immediate Spot capacity; staging TERMINATED ${expected_gpu_name} in ${fb_zone} for watchdog auto-retry..."
    refresh_gcp_credentials
    build_tf_args "$fb_region" "$fb_zone"
    set +e
    "${TF[@]}" apply "${apply_args[@]}"
    set -e
    if gcloud compute instances describe "$expected_gpu_name" --zone="$fb_zone" --project="$effective_project" >/dev/null 2>&1; then
      import_and_apply_terminated_gpu "$fb_region" "$fb_zone"
    fi
  fi

  if [[ -z "$deployed_zone" ]]; then
    echo "[error] Failed to allocate GPU capacity across candidates: ${candidate_targets[*]}" >&2
    exit 1
  fi

  "${TF[@]}" output -raw ssh_private_key > "$INFRA_DIR/ssh-key"
  chmod 600 "$INFRA_DIR/ssh-key"
  "${TF[@]}" output -raw ssh_public_key > "$INFRA_DIR/ssh-key.pub"
  chmod 644 "$INFRA_DIR/ssh-key.pub"

  local known_hosts
  known_hosts="$("${TF[@]}" output -raw known_hosts_entries || true)"
  if [[ -n "$known_hosts" ]]; then
    printf '%s\n' "$known_hosts" > "$INFRA_DIR/known_hosts"
    chmod 644 "$INFRA_DIR/known_hosts"
  fi

  local ctrl_name gpu_name gpu_ip ctrl_ssh_cmd gpu_ssh_cmd
  ctrl_name="$("${TF[@]}" output -raw controller_name)"
  gpu_name="$("${TF[@]}" output -raw gpu_vm_name)"
  gpu_ip="$("${TF[@]}" output -raw gpu_vm_internal_ip)"
  ctrl_ssh_cmd="$("${TF[@]}" output -raw controller_ssh_command)"
  gpu_ssh_cmd="$("${TF[@]}" output -raw gpu_ssh_command)"

  echo ""
  echo "================================================================"
  echo "Controller + Watchdog + GPU VM deployed successfully (GCP)"
  echo "================================================================"
  echo "Project:              ${effective_project}"
  echo "Region / Zone:        ${deployed_region} / ${deployed_zone}"
  echo "Controller VM:        ${ctrl_name} (STANDARD, internal=$("${TF[@]}" output -raw controller_internal_ip))"
  echo "GPU VM:               ${gpu_name} (internal=${gpu_ip})"
  echo "Public Ingress:       disabled (IAP SSH only)"
  echo ""
  echo "Connect to Controller (via gcloud IAP):"
  echo "  ${ctrl_ssh_cmd}"
  echo ""
  echo "Connect directly to GPU VM (via gcloud IAP):"
  echo "  ${gpu_ssh_cmd}"
  echo ""
  echo "Configure GitHub Actions Runner on Controller:"
  echo "  ./development/scripts/setup.sh --provider=gcp --repo=vitorecomp/<repo> --token=<RUNNER_TOKEN>"
  echo ""
  gcloud compute instances list \
    --filter="name=(${ctrl_name} ${gpu_name})" \
    --project="${effective_project}" \
    --format="table(name,zone.basename(),machineType.basename(),scheduling.provisioningModel,status,networkInterfaces[0].networkIP)" || true
}

case "$PROVIDER" in
  gcp) run_gcp_terraform ;;
  azure|on-prem) run_azure_or_onprem_terraform ;;
esac
