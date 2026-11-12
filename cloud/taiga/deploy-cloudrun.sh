#!/usr/bin/env bash
# Deploys Taiga to Cloud Run. Runs on the GitHub runner (.github/workflows/deploy-taiga.yml) as the
# github-deployer service account via Workload Identity Federation, so no keys exist anywhere and
# the e2-micro VM does no work. Also runs from a workstation logged in with `gcloud auth login`.
#   1. build the image (skipped when this exact build context is already in Artifact Registry)
#   2. run migrations + admin reconcile against Neon (Cloud Run instances skip them)
#   3. sync the DB / admin passwords into Secret Manager (only on change; old versions destroyed)
#   4. roll out a new Cloud Run revision (free-tier sizing from cloudrun.env)
#
# Inputs (environment): TAIGA_DB_HOST, TAIGA_DB_USER, TAIGA_DB_PASSWORD, [TAIGA_DB_NAME=taiga,
# TAIGA_DB_PORT=5432, TAIGA_DB_SSLMODE=require], TAIGA_ADMIN_PASSWORD, [TAIGA_ADMIN_USER=admin,
# TAIGA_ADMIN_EMAIL]. TAIGA_SECRET_KEY defaults to the latest taiga-secret-key in Secret Manager.
#
# Usage: cloud/taiga/deploy-cloudrun.sh [--dry-run]
set -euo pipefail
cd "$(dirname "$0")"
DRY_RUN=false
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
# shellcheck source=/dev/null
. ./cloudrun.env

GCLOUD="$(command -v gcloud || echo /snap/bin/gcloud)"
REGISTRY="${REGION}-docker.pkg.dev"
IMAGE="${REGISTRY}/${PROJECT}/${REPO}/taiga"
TAG="ctx-$(cat Dockerfile nginx.conf docker-entrypoint.sh | sha256sum | cut -c1-12)"
DOMAIN="${STACK_DOMAIN:-taiga.vitorx86.dev}"
log() { echo "[cloudrun] $*"; }

missing=()
for var in TAIGA_DB_HOST TAIGA_DB_USER TAIGA_DB_PASSWORD TAIGA_ADMIN_PASSWORD; do
  [[ -n "${!var:-}" ]] || missing+=("$var")
done
if (( ${#missing[@]} )); then
  log "missing required environment: ${missing[*]}"
  exit 2
fi
if $DRY_RUN; then
  log "[dry-run] would build ${IMAGE}:${TAG} unless it is already in Artifact Registry, then push it"
  log "[dry-run] would run TAIGA_ENTRYPOINT_MODE=migrate against ${TAIGA_DB_HOST}"
  log "[dry-run] would sync taiga-db-password / taiga-admin-password into Secret Manager (${PROJECT})"
  log "[dry-run] would deploy Cloud Run service ${SERVICE} in ${REGION} (${CPU} vCPU / ${MEMORY}, 0..${MAX_INSTANCES})"
  exit 0
fi
if [[ -z "${TAIGA_SECRET_KEY:-}" ]]; then
  TAIGA_SECRET_KEY="$("$GCLOUD" secrets versions access latest --secret=taiga-secret-key --project "$PROJECT")"
fi

# 1. Image -----------------------------------------------------------------
"$GCLOUD" auth print-access-token | docker login -u oauth2accesstoken --password-stdin "https://${REGISTRY}" >/dev/null 2>&1
if "$GCLOUD" artifacts docker images describe "${IMAGE}:${TAG}" >/dev/null 2>&1; then
  log "image ${TAG} already in Artifact Registry"
  docker image inspect "${IMAGE}:${TAG}" >/dev/null 2>&1 || docker pull -q "${IMAGE}:${TAG}" >/dev/null
else
  log "building ${TAG}"
  BUILDX_NO_DEFAULT_ATTESTATIONS=1 docker build --pull -q -t "${IMAGE}:${TAG}" . >/dev/null
  docker push -q "${IMAGE}:${TAG}" >/dev/null
  log "pushed ${IMAGE}:${TAG}"
fi

# 2. Migrations + admin reconcile against Neon (env file keeps secrets off the command line)
envf="$(mktemp)"
chmod 600 "$envf"
trap 'rm -f "$envf"' EXIT
cat > "$envf" <<ENV
POSTGRES_HOST=${TAIGA_DB_HOST}
POSTGRES_PORT=${TAIGA_DB_PORT:-5432}
POSTGRES_DB=${TAIGA_DB_NAME:-taiga}
POSTGRES_USER=${TAIGA_DB_USER}
POSTGRES_PASSWORD=${TAIGA_DB_PASSWORD}
POSTGRES_SSLMODE=${TAIGA_DB_SSLMODE:-require}
TAIGA_SECRET_KEY=${TAIGA_SECRET_KEY}
TAIGA_SITES_SCHEME=https
TAIGA_SITES_DOMAIN=${DOMAIN}
TAIGA_URL=https://${DOMAIN}
TAIGA_ADMIN_USER=${TAIGA_ADMIN_USER:-admin}
TAIGA_ADMIN_EMAIL=${TAIGA_ADMIN_EMAIL:-}
TAIGA_ADMIN_PASSWORD=${TAIGA_ADMIN_PASSWORD:-}
TAIGA_ENTRYPOINT_MODE=migrate
ENV
log "running migrations against ${TAIGA_DB_HOST}"
if out="$(docker run --rm --env-file "$envf" "${IMAGE}:${TAG}" 2>&1)"; then
  grep -E "^\[entrypoint\]|Applying|No migrations" <<<"$out" || true
else
  tail -n 20 <<<"$out"
  log "migrate run failed"
  exit 1
fi

# 3. Secrets -> Secret Manager ----------------------------------------------
sync_secret() {
  local name="$1" value="$2" current v
  # The deployer only holds per-secret version roles (no secrets.get), so probe with versions list;
  # a missing secret and a missing grant both come back as PERMISSION_DENIED.
  if ! "$GCLOUD" secrets versions list "$name" --project "$PROJECT" --limit=1 >/dev/null 2>&1; then
    log "secret ${name}: missing or not granted to $("$GCLOUD" config get-value account 2>/dev/null) (apply cloud/infra/envs/gcp-taiga)"
    exit 1
  fi
  current="$("$GCLOUD" secrets versions access latest --secret="$name" --project "$PROJECT" 2>/dev/null || true)"
  if [[ "$current" == "$value" ]]; then
    log "secret ${name}: unchanged"
    return
  fi
  printf '%s' "$value" | "$GCLOUD" secrets versions add "$name" --project "$PROJECT" --data-file=- >/dev/null
  log "secret ${name}: new version"
  # Keep a single live version (Secret Manager free tier: 6 active versions).
  for v in $("$GCLOUD" secrets versions list "$name" --project "$PROJECT" --filter="state!=DESTROYED" \
               --sort-by="~createTime" --format="value(name.basename())" | tail -n +2); do
    "$GCLOUD" secrets versions destroy "$v" --secret="$name" --project "$PROJECT" --quiet >/dev/null
  done
}
# taiga-secret-key is the source of truth itself (read above); the passwords come from taiga-prod.
sync_secret taiga-db-password "$TAIGA_DB_PASSWORD"
sync_secret taiga-admin-password "$TAIGA_ADMIN_PASSWORD"

# 4. Cloud Run revision -------------------------------------------------------
envs="^@^POSTGRES_HOST=${TAIGA_DB_HOST}@POSTGRES_PORT=${TAIGA_DB_PORT:-5432}@POSTGRES_DB=${TAIGA_DB_NAME:-taiga}"
envs+="@POSTGRES_USER=${TAIGA_DB_USER}@POSTGRES_SSLMODE=${TAIGA_DB_SSLMODE:-require}@PGSSLMODE=${TAIGA_DB_SSLMODE:-require}"
envs+="@TAIGA_SITES_SCHEME=https@TAIGA_SITES_DOMAIN=${DOMAIN}@TAIGA_URL=https://${DOMAIN}"
envs+="@PUBLIC_REGISTER_ENABLED=False@ENABLE_TELEMETRY=False@CELERY_ENABLED=False"
envs+="@TAIGA_STORAGE_SYNC_DIR=/mnt/taiga-storage@GUNICORN_WORKERS=1@TAIGA_SKIP_MIGRATIONS=true"
log "deploying revision to Cloud Run (${CPU} vCPU / ${MEMORY}, 0..${MAX_INSTANCES} instances)"
"$GCLOUD" run deploy "$SERVICE" --project "$PROJECT" --region "$REGION" --quiet \
  --image "${IMAGE}:${TAG}" --service-account "$RUN_SA" --port 8080 \
  --cpu "$CPU" --memory "$MEMORY" --concurrency "$CONCURRENCY" \
  --min-instances 0 --max-instances "$MAX_INSTANCES" --cpu-throttling --cpu-boost \
  --execution-environment gen2 --timeout 300 \
  --set-env-vars "$envs" \
  --set-secrets "TAIGA_SECRET_KEY=taiga-secret-key:latest,POSTGRES_PASSWORD=taiga-db-password:latest" \
  --clear-volume-mounts --clear-volumes \
  --add-volume "name=media,type=cloud-storage,bucket=${MEDIA_BUCKET}" \
  --add-volume-mount "volume=media,mount-path=/mnt/taiga-storage" 2>&1 | grep -vE "^\s*$" | tail -3

log "serving at $("$GCLOUD" run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" --format='value(status.url)')"
