#!/usr/bin/env bash
# Retries `terraform plan` + `apply` for a VM root until the cloud has capacity.
#
# Built for OCI's "Out of host capacity" on Always Free Ampere A1 shapes, where the
# only fix is retrying later. Safe to leave running in a terminal:
#   * retries ONLY on capacity errors; any other failure (auth, quota, syntax) stops the loop
#   * refuses to apply a plan that deletes or replaces anything (exit 2)
#   * stops successfully when the plan has no changes left, printing the outputs
#   * refreshes a gcloud access token every attempt for the GCS state backend, so the
#     `gcloud` CLI account is used even if Application Default Credentials point elsewhere
#     (pass --adc to use ADC instead)
#
# Usage:
#   cloud/scripts/tf_apply_retry.sh [--env oci-blog] [--interval 300] [--max-attempts 0] [--adc] [--dry-run]
#
# See documentation/vm-provisioning.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENV_NAME="oci-blog"
INTERVAL=300
MAX_ATTEMPTS=0   # 0 = unlimited
USE_ADC=false
DRY_RUN=false
MAX_PLAN_FAILURES=3
CAPACITY_PATTERN='out of host capacity|outofcapacity|out of capacity|insufficient capacity|does not have enough resources|zone_resource_pool_exhausted'
# Transient failures worth retrying (seen on a CPU-starved host: the provider plugin failed to start in time).
TRANSIENT_PATTERN='timeout while waiting for plugin to start|error acquiring the state lock|i/o timeout|tls handshake timeout|connection reset by peer|too many requests|429'

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

notify() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "personal-infra" "$1" >/dev/null 2>&1 || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    --adc) USE_ADC=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[error] unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

ENV_DIR="$REPO_ROOT/cloud/infra/envs/$ENV_NAME"
if [[ ! -d "$ENV_DIR" ]]; then
  echo "[error] $ENV_DIR does not exist" >&2
  exit 1
fi
if ! [[ "$INTERVAL" =~ ^[0-9]+$ && "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]]; then
  echo "[error] --interval and --max-attempts must be non-negative integers" >&2
  exit 1
fi

# Prefer a terraform on PATH, otherwise the version pinned in the repo's mise.toml.
if command -v terraform >/dev/null 2>&1; then
  TF=(terraform)
elif command -v mise >/dev/null 2>&1; then
  TF=(mise exec --cd "$REPO_ROOT" -- terraform)
elif $DRY_RUN; then
  TF=(terraform)
else
  echo "[error] terraform not found (run: mise trust && mise install)" >&2
  exit 1
fi
TF+=(-chdir="$ENV_DIR")

if $DRY_RUN; then
  echo "[dry-run] Would loop in $ENV_DIR every ${INTERVAL}s (max attempts: ${MAX_ATTEMPTS/#0/unlimited}):"
  $USE_ADC || echo "[dry-run]   export GOOGLE_OAUTH_ACCESS_TOKEN=\$(gcloud auth print-access-token)"
  echo "[dry-run]   ${TF[*]} plan -input=false -detailed-exitcode -out <tmp>/tfplan"
  echo "[dry-run]   refuse if the plan deletes/replaces anything; stop if there are no changes"
  echo "[dry-run]   ${TF[*]} apply -input=false <tmp>/tfplan   (retry only on capacity errors)"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "[error] jq is required" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT   # plan files can contain sensitive values
PLAN="$WORK_DIR/tfplan"
OUT="$WORK_DIR/output.log"

refresh_token() {
  if $USE_ADC; then
    return 0
  fi
  if ! GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null)"; then
    log "[error] 'gcloud auth print-access-token' failed (run gcloud auth login, or pass --adc)"
    exit 1
  fi
  export GOOGLE_OAUTH_ACCESS_TOKEN
}

log "[start] retrying apply for $ENV_NAME every ${INTERVAL}s (Ctrl-C to stop)"
refresh_token
"${TF[@]}" init -input=false >/dev/null

attempt=0
plan_failures=0
while :; do
  attempt=$((attempt + 1))
  if [[ "$MAX_ATTEMPTS" -gt 0 && "$attempt" -gt "$MAX_ATTEMPTS" ]]; then
    log "[stop] reached --max-attempts $MAX_ATTEMPTS without capacity"
    exit 1
  fi
  refresh_token

  # Plan: 0 = no changes, 2 = changes, 1 = error.
  set +e
  "${TF[@]}" plan -input=false -no-color -detailed-exitcode -out "$PLAN" >"$OUT" 2>&1
  plan_rc=$?
  set -e
  if [[ $plan_rc -eq 0 ]]; then
    log "[ok] nothing left to create; current outputs:"
    "${TF[@]}" output
    notify "terraform $ENV_NAME: no changes left"
    exit 0
  fi
  if [[ $plan_rc -ne 2 ]] && grep -qiE "$TRANSIENT_PATTERN" "$OUT"; then
    log "[wait] transient plan error ($(grep -oiE "$TRANSIENT_PATTERN" "$OUT" | head -1)); retrying in ${INTERVAL}s"
    sleep "$INTERVAL"
    continue
  fi
  if [[ $plan_rc -ne 2 ]]; then
    plan_failures=$((plan_failures + 1))
    log "[warn] plan failed (${plan_failures}/${MAX_PLAN_FAILURES}):"
    tail -n 15 "$OUT"
    if [[ $plan_failures -ge $MAX_PLAN_FAILURES ]]; then
      log "[error] plan keeps failing; stopping"
      exit 1
    fi
    sleep "$INTERVAL"
    continue
  fi
  plan_failures=0

  if ! plan_json="$("${TF[@]}" show -json "$PLAN" 2>"$OUT")"; then
    plan_failures=$((plan_failures + 1))
    log "[warn] could not read the saved plan (${plan_failures}/${MAX_PLAN_FAILURES}):"
    tail -n 5 "$OUT"
    if [[ $plan_failures -ge $MAX_PLAN_FAILURES ]]; then
      log "[error] terraform show keeps failing; stopping"
      exit 1
    fi
    sleep "$INTERVAL"
    continue
  fi
  destructive="$(jq -r '
    [.resource_changes[]? | select(.change.actions | index("delete")) | .address] | join(", ")' <<<"$plan_json")"
  if [[ -n "$destructive" ]]; then
    log "[refuse] the plan would delete/replace: $destructive"
    log "[refuse] review it by hand: terraform -chdir=$ENV_DIR plan"
    exit 2
  fi
  creates="$(jq -r '
    [.resource_changes[]? | select(.change.actions != ["no-op"]) | "\(.change.actions | join("/")) \(.address)"] | join("; ")' <<<"$plan_json")"
  log "[attempt $attempt] applying: $creates"

  set +e
  "${TF[@]}" apply -input=false -no-color "$PLAN" >"$OUT" 2>&1
  apply_rc=$?
  set -e
  if [[ $apply_rc -eq 0 ]]; then
    log "[ok] apply succeeded"
    "${TF[@]}" output
    notify "terraform $ENV_NAME: apply succeeded"
    exit 0
  fi

  if grep -qiE "$CAPACITY_PATTERN" "$OUT"; then
    log "[wait] no capacity yet; retrying in ${INTERVAL}s"
    sleep "$INTERVAL"
    continue
  fi
  if grep -qiE "$TRANSIENT_PATTERN" "$OUT"; then
    log "[wait] transient error ($(grep -oiE "$TRANSIENT_PATTERN" "$OUT" | head -1)); retrying in ${INTERVAL}s"
    sleep "$INTERVAL"
    continue
  fi

  log "[error] apply failed for a reason other than capacity; stopping:"
  tail -n 30 "$OUT"
  notify "terraform $ENV_NAME: apply failed (not capacity)"
  exit 1
done
