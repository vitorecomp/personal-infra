#!/usr/bin/env bash
set -euo pipefail

export TAIGA_SITES_SCHEME="${TAIGA_SITES_SCHEME:-https}"
export TAIGA_SITES_DOMAIN="${TAIGA_SITES_DOMAIN:-taiga.vitorx86.dev}"
export TAIGA_SUBPATH="${TAIGA_SUBPATH:-}"
export TAIGA_URL="${TAIGA_URL:-${TAIGA_SITES_SCHEME}://${TAIGA_SITES_DOMAIN}}"
export PUBLIC_REGISTER_ENABLED="${PUBLIC_REGISTER_ENABLED:-False}"
export ENABLE_TELEMETRY="${ENABLE_TELEMETRY:-False}"
export CELERY_ENABLED="${CELERY_ENABLED:-False}"

# 1. Mount / link persistent media directory when GCS FUSE volume is attached
if [[ -n "${TAIGA_STORAGE_SYNC_DIR:-}" && -d "${TAIGA_STORAGE_SYNC_DIR}" ]]; then
    mkdir -p "${TAIGA_STORAGE_SYNC_DIR}/media"
    if [[ -d /taiga-back/media && ! -L /taiga-back/media ]]; then
        cp -rn /taiga-back/media/. "${TAIGA_STORAGE_SYNC_DIR}/media/" 2>/dev/null || true
        rm -rf /taiga-back/media
    fi
    ln -sfn "${TAIGA_STORAGE_SYNC_DIR}/media" /taiga-back/media
    echo "[entrypoint] Linked /taiga-back/media -> ${TAIGA_STORAGE_SYNC_DIR}/media"
else
    mkdir -p /taiga-back/media
fi

# 2. Generate runtime /taiga-front/conf.json for the Angular SPA
PUBLIC_REG_JSON="false"
if [[ "${PUBLIC_REGISTER_ENABLED,,}" == "true" ]]; then
    PUBLIC_REG_JSON="true"
fi

cat > /taiga-front/conf.json <<EOF
{
    "api": "${TAIGA_URL%/}/api/v1/",
    "eventsUrl": null,
    "eventsMaxMissedHeartbeats": 5,
    "eventsHeartbeatIntervalTime": 60000,
    "eventsReconnectTryInterval": 10000,
    "debug": false,
    "debugInfo": false,
    "defaultLanguage": "en",
    "themes": ["taiga"],
    "defaultTheme": "taiga",
    "publicRegisterEnabled": ${PUBLIC_REG_JSON},
    "feedbackEnabled": false,
    "supportUrl": "",
    "privacyPolicyUrl": "",
    "termsOfServiceUrl": "",
    "maxUploadFileSize": null,
    "contribPlugins": [],
    "gitHubClientId": null,
    "gitLabClientId": null,
    "gitLabUrl": null,
    "tagManager": { "accountId": null },
    "tribeHost": null,
    "enableAsanaImporter": false,
    "enableGithubImporter": true,
    "enableJiraImporter": false,
    "enableTrelloImporter": false,
    "gravatar": true,
    "rtlLanguages": ["ar", "fa", "he"],
    "enableTelemetry": false
}
EOF
echo "[entrypoint] Rendered /taiga-front/conf.json for ${TAIGA_URL}"

# 3. Run database migrations & idempotent initial seed
cd /taiga-back
echo "[entrypoint] Running database migrations..."
python manage.py migrate --noinput

python - <<'PYEOF'
import os
import django
from django.core.management import call_command

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "settings.config")
django.setup()

from django.contrib.auth import get_user_model
from taiga.projects.models import ProjectTemplate

if not ProjectTemplate.objects.exists():
    print("[entrypoint] Loading initial_project_templates (Scrum & Kanban)...")
    call_command("loaddata", "initial_project_templates")
else:
    print("[entrypoint] Project templates already present; skipping loaddata.")

admin_username = os.environ.get("TAIGA_ADMIN_USER", "admin").strip() or "admin"
admin_email = os.environ.get("TAIGA_ADMIN_EMAIL", "vitor.ecomp@gmail.com").strip()
admin_password = os.environ.get("TAIGA_ADMIN_PASSWORD", "").strip()
admin_full_name = os.environ.get("TAIGA_ADMIN_NAME", "Vitor Vieira").strip()

if admin_email and admin_password:
    User = get_user_model()
    user = User.objects.filter(username=admin_username).first() or User.objects.filter(email=admin_email).first()
    if user is None:
        user = User.objects.create_superuser(
            username=admin_username,
            email=admin_email,
            password=admin_password,
            full_name=admin_full_name,
        )
        print(f"[entrypoint] Created initial Taiga superuser '{admin_username}' ({admin_email}).")
    else:
        updated = False
        if not user.is_superuser or not user.is_staff:
            user.is_superuser = True
            user.is_staff = True
            updated = True
        if not user.check_password(admin_password):
            user.set_password(admin_password)
            updated = True
        if updated:
            user.save()
            print(f"[entrypoint] Reconciled Taiga superuser '{ user.username }' credentials.")
        else:
            print(f"[entrypoint] Taiga superuser '{ user.username }' already up to date.")
PYEOF

# 4. Start Gunicorn backend on 127.0.0.1:8000 and Nginx on 0.0.0.0:8080
echo "[entrypoint] Starting Gunicorn (taiga-back) on 127.0.0.1:8000 ..."
gunicorn taiga.wsgi:application \
    --name taiga_api \
    --bind 127.0.0.1:8000 \
    --workers "${GUNICORN_WORKERS:-3}" \
    --worker-tmp-dir /dev/shm \
    --max-requests 2000 \
    --max-requests-jitter 200 \
    --timeout 120 \
    --access-logfile - \
    --error-logfile - &

GUNICORN_PID=$!

# Wait briefly for Gunicorn to bind before accepting ingress traffic on :8080
for _ in {1..30}; do
    if ! kill -0 "${GUNICORN_PID}" 2>/dev/null; then
        echo "[error] Gunicorn process exited unexpectedly." >&2
        exit 1
    fi
    if python -c "import socket; s = socket.create_connection(('127.0.0.1', 8000), 1); s.close()" 2>/dev/null; then
        break
    fi
    sleep 0.5
done

echo "[entrypoint] Starting Nginx gateway on 0.0.0.0:8080 ..."
exec nginx -g "daemon off;"
