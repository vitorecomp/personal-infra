# Taiga Project Manager (`cloud/taiga`)

**Taiga** (`https://taiga.vitorx86.dev`) runs on **Cloud Run** (free tier, project `personal-project-514501`,
us-central1) with its database on **Neon** (managed Postgres 15) and uploads in the GCS bucket
`vitorx86-taiga-media` (mounted at `/mnt/taiga-storage`). The edge Caddy on the VM terminates TLS for the
custom domain and proxies to the `run.app` URL ([`cloud/edge`](../edge)).

Taiga 6.10 cannot use Postgres 16+ (its `json_object_delete_keys(json json, ...)` function hits the `json`
keyword), so the Neon project must stay on 15.

## Files

| File | Purpose |
| :--- | :--- |
| `Dockerfile` | One image: `taiga-front` SPA + `taiga-back` (gunicorn on `127.0.0.1:8000`) + nginx on `:8080`; bases pinned to 6.10.2 / 6.10.3. |
| `docker-entrypoint.sh` | Links media to `$TAIGA_STORAGE_SYNC_DIR`, renders `conf.json`, runs migrations + admin reconcile (skipped with `TAIGA_SKIP_MIGRATIONS=true`; `TAIGA_ENTRYPOINT_MODE=migrate` runs them and exits), starts gunicorn + nginx. |
| `deploy-cloudrun.sh` | Runs **on the VM** (keyless, VM service account): builds the image (skipped if this build context is already in Artifact Registry), runs migrations against Neon, syncs `TAIGA_SECRET_KEY` / DB password into Secret Manager, rolls out a Cloud Run revision. |
| `cloudrun.env` | Non-secret Cloud Run settings (project, region, sizing: 1 vCPU / 512 MiB, 0..1 instances). |
| `.env.example` | Keys for `/opt/stacks/taiga/.env` on the VM (Neon `TAIGA_DB_*`, secret key, admin). `TAIGA_DB_*` are synced from the `taiga-prod` GitHub environment. |
| `stack.json` | `deploy_stack.py` / `backup_stack.py` metadata (`up_script`, health path, Neon + media-bucket backups). |
| `nginx.conf`, `compose.local.yml` | Container gateway; local development stack. |

## Commands

```bash
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<vm> --identity-file ~/.ssh/taiga_deploy --dry-run
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<vm> --identity-file ~/.ssh/taiga_deploy
gcloud run services describe taiga --project personal-project-514501 --region us-central1 --format='value(status.url)'
docker compose -f cloud/taiga/compose.local.yml up --build   # local development
```

Free-tier notes: scale to zero means the first request after ~15 min idle cold-starts the container
(no migrations at boot, so it is mostly Django import time). Requests are capped at 32 MiB by Cloud Run,
which also caps attachment uploads.
