# Taiga Project Manager (`cloud/taiga`)

Self-contained container and Cloud Build deployment configuration for hosting **Taiga Project Manager** (`https://taiga.vitorx86.dev`) on **Google Cloud Run v2**, backed by **Cloud SQL for PostgreSQL 15** and a private **Google Cloud Storage** bucket via GCS FUSE behind the shared Global External HTTPS Load Balancer.

## Architecture

- **`Dockerfile`**: Multi-stage unified container combining:
  - `taigaio/taiga-front:latest` (Angular SPA served at `/`)
  - `taigaio/taiga-back:latest` (Django/Gunicorn REST API & Admin on `127.0.0.1:8000`)
  - `nginx` gateway listening on port `8080` (`PORT=8080`) routing `/`, `/api`, `/admin`, `/static/`, and `/media/`
- **`docker-entrypoint.sh`**: Idempotent startup script that:
  - Links `/taiga-back/media` to `/mnt/taiga-storage/media` when a GCS FUSE bucket is mounted (`TAIGA_STORAGE_SYNC_DIR`)
  - Renders `/taiga-front/conf.json` dynamically from `TAIGA_URL` and `PUBLIC_REGISTER_ENABLED`
  - Runs `python manage.py migrate --noinput`
  - Seeds Scrum & Kanban `initial_project_templates` once and reconciles the initial superuser account (`TAIGA_ADMIN_USER`, `TAIGA_ADMIN_EMAIL`, `TAIGA_ADMIN_PASSWORD`)
- **`cloudbuild.yaml`**: Builds and pushes the container image to Artifact Registry (`${_REGION}-docker.pkg.dev/$PROJECT_ID/${_AR_REPO}/${_SERVICE_NAME}`).
- **`docker-compose.yml`**: Local development stack (`postgres:15-alpine` + `taiga` on `http://localhost:8080`).

## Deployment Commands

```bash
# Preview Cloud Build and Cloud Run deployment commands (safe, read-only)
python3 cloud/scripts/deploy_taiga.py --deploy --dry-run

# Build and deploy Taiga to Cloud Run
python3 cloud/scripts/deploy_taiga.py --deploy
```
