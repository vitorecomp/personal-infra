# Taiga Project Manager (`cloud/taiga`)

Container + docker compose stack for **Taiga** (`https://taiga.vitorx86.dev`).

Runs on the GCE e2-micro VM ([`cloud/infra/envs/gcp-taiga`](../infra/envs/gcp-taiga)) next to the blog.
TLS and routing come from the shared edge proxy ([`cloud/edge`](../edge)); the container joins the `edge`
network as `taiga-app`. The database is **Neon** managed Postgres 15 (Taiga 6.10 cannot run on Postgres 16+:
its `json_object_delete_keys(json json, ...)` function hits the new `json` keyword).

## Files

| File | Purpose |
| :--- | :--- |
| `Dockerfile` | One image: `taigaio/taiga-front` SPA + `taigaio/taiga-back` (gunicorn on `127.0.0.1:8000`) + nginx on `:8080`. Base versions pinned with `ARG TAIGA_BACK_VERSION=6.10.2` / `TAIGA_FRONT_VERSION=6.10.3` (the versions production runs; migrations are forward-only, bump deliberately). |
| `nginx.conf` | Routes `/`, `/api`, `/admin`, `/static/`, `/media/`; honours `X-Forwarded-Proto` from Caddy. |
| `docker-entrypoint.sh` | Links `/taiga-back/media` to `$TAIGA_STORAGE_SYNC_DIR/media`, renders `conf.json`, runs migrations, seeds templates once, reconciles the superuser from `TAIGA_ADMIN_*`, starts gunicorn + nginx. |
| `compose.yml` | **Production stack** on the VM: `taiga` (built on the VM) on the `edge` network, `TAIGA_DB_*` pointing at Neon (TLS). Health check uses a static file so it never keeps Neon's compute awake. Named volume `taiga_media`. |
| `.env.example` | Keys for `/opt/stacks/taiga/.env` on the VM (mode 0600, never committed, never written by CI). `TAIGA_DB_*` are synced from the `taiga-prod` GitHub environment by the deploy workflow. |
| `stack.json` | Metadata for `deploy_stack.py` / `backup_stack.py` (domain, health path, backup volumes). |
| `compose.local.yml` | Local development stack (`http://127.0.0.1:8080`). |
| `cloudbuild.yaml` | Legacy Cloud Run build (removed after the Taiga cutover). |

## Commands

```bash
# Deploy / redeploy to the VM (CI does the same via .github/workflows/deploy-taiga.yml)
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<taiga-ip> --dry-run
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<taiga-ip>

# Backups (on the VM)
python3 /opt/stacks/.ops/backup_stack.py --stack taiga --restore-test

# Local development
docker compose -f cloud/taiga/compose.local.yml up --build
```
