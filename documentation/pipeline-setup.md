# Pipeline & CI/CD Setup

How changes reach production. Everything heavy (image builds, Taiga migrations, the Cloud Run rollout) runs on
GitHub-hosted runners, so the e2-micro VM only does light SSH steps (rsync, `compose pull`/`up`). No cloud keys
live in GitHub: the Taiga job impersonates `github-deployer@$GCP_PROJECT_ID.iam.gserviceaccount.com` through **Workload Identity
Federation** (only this repo, on `main`, in the `taiga-prod` environment), and Terraform still runs only from a
workstation ([vm-provisioning.md](./vm-provisioning.md)).

Because this repository is public, all private/personal identifiers (domains, emails, Cloud Run upstream URL, GCP project/bucket
names, WIF provider, and VM `known_hosts`) are stored as **GitHub Secrets** (masked as `***` in public workflow logs) and synced
from your gitignored root [`.env`](../.env.example) via [`cloud/scripts/sync_github_secrets.py`](../cloud/scripts/sync_github_secrets.py).

## 1. Flows

| What changes | Path to production |
| :--- | :--- |
| `vitorecomp/nobuffer-site`, `vitorecomp/personal-portifolio` | Vercel Git integration builds and deploys every push to the production branch. Nothing in this repo. |
| `vitorecomp/personal-blog` (Ghost theme/image) | Its `trigger-deploy.yml` sends `repository_dispatch: deploy-personal-blog` with `client_payload.sha` → [`deploy-blog.yml`](../.github/workflows/deploy-blog.yml) |
| `cloud/personal-blog/**`, `cloud/edge/**`, `cloud/scripts/{deploy_stack,backup_stack,seed_ghost_admin}.py`, the workflow | push to `main` → `deploy-blog.yml` |
| `cloud/taiga/**`, `cloud/edge/**`, `cloud/scripts/{deploy_stack,backup_stack,seed_taiga_admin}.py`, the workflow | push to `main` → [`deploy-taiga.yml`](../.github/workflows/deploy-taiga.yml) |
| `development/gpu-dev-machine/**`, `development/scripts/deploy_gpu_stack.sh`, the workflow | push to `main` (or manual dispatch) → [`deploy-gpu-machine.yml`](../.github/workflows/deploy-gpu-machine.yml) (self-hosted runner selected by repo variable `GPU_RUNNER`, environment `gpu`) |
| `cloud/infra/**`, `development/infra/**` | CI validates only; apply from workstation (`development/scripts/deploy.sh`) |

Both deploy workflows share the `deploy-gcp-vm` concurrency group (one VM) and refresh the edge stack in their VM job.

## 2. Workflows

| Workflow | Purpose |
| :--- | :--- |
| [`ci.yml`](../.github/workflows/ci.yml) | Secret & personal-identifier scan (files + full history), Python syntax and `--dry-run` checks, `terraform fmt -check` / `validate` for `gcp-taiga`, `oci-blog`, and `development/infra/gcp`, stack validation (`docker compose config`, `caddy validate`, `bash -n`). |
| [`deploy-blog.yml`](../.github/workflows/deploy-blog.yml) | **build** (runner): checks out `vitorecomp/personal-blog` at the dispatched SHA (default `main`), validates the theme, builds and pushes `ghcr.io/vitorecomp/personal-blog:<sha>`. **deploy** (SSH): `deploy_stack.py --stack edge --sync-env TAIGA_DOMAIN,BLOG_DOMAIN,ACME_EMAIL,TAIGA_UPSTREAM`, then `--stack personal-blog --sync-env GHOST_IMAGE,STACK_DOMAIN` (digest-pinned image + domain into the VM `.env`, `compose pull` with a throwaway login using the job's `GITHUB_TOKEN`, `up --wait`, HTTPS check, Ghost owner check). |
| [`deploy-taiga.yml`](../.github/workflows/deploy-taiga.yml) | **cloud-run** (runner, WIF): [`cloud/taiga/deploy-cloudrun.sh`](../cloud/taiga/deploy-cloudrun.sh) builds the image (skipped if this build context is already in Artifact Registry), runs migrations against Neon, syncs the DB/admin passwords into Secret Manager and rolls out a Cloud Run revision. **vm** (SSH): edge stack (`--sync-env TAIGA_DOMAIN,BLOG_DOMAIN,ACME_EMAIL,TAIGA_UPSTREAM`), then `deploy_stack.py --stack taiga --sync-env TAIGA_DB_*,TAIGA_MEDIA_BUCKET`, HTTPS + admin login checks through the VM. |
| [`deploy-gpu-machine.yml`](../.github/workflows/deploy-gpu-machine.yml) | Runs on the self-hosted runner selected by `vars.GPU_RUNNER` (default `gcp-gpu`) in environment `gpu`: [`deploy_gpu_stack.sh`](../development/scripts/deploy_gpu_stack.sh) waits for Spot GPU VM SSH (`gpu-wait-ssh`), bootstraps Podman + NVIDIA CDI + `/mnt/data` storage if missing, syncs `development/gpu-dev-machine/`, writes `.env` (`0600`) + tunnel SSH key, and runs `podman-compose up -d --build`. |
| [`update-repo-stats.yml`](../.github/workflows/update-repo-stats.yml) | Weekly refresh of `workspace/documentation/repo_stats.json`. |

## 3. Secrets and variables

Sync personal/private secrets from your gitignored root `.env`:

```bash
cp -n .env.example .env && chmod 600 .env
python3 cloud/scripts/sync_github_secrets.py --dry-run
python3 cloud/scripts/sync_github_secrets.py
```

| Where | Name | Kind | Purpose |
| :--- | :--- | :--- | :--- |
| Repository | `TAIGA_DOMAIN`, `BLOG_DOMAIN`, `ACME_EMAIL`, `TAIGA_UPSTREAM`, `GCP_PROJECT_ID`, `GCP_REGION`, `TAIGA_RUN_SA`, `TAIGA_MEDIA_BUCKET`, `BACKUP_BUCKET`, `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA`, `ADMIN_NAME`, `BLOG_ADMIN_NAME`, `BLOG_TITLE`, `BLOG_THEME_NAME` | secret | Domains, Let's Encrypt email, Cloud Run upstream URL, GCP project/buckets/WIF identifiers, and blog customization (stored as Secrets so CI masks them in public logs; synced by `sync_github_secrets.py`) |
| Repository | `GPU_RUNNER` *(optional `GPU_RUNNER_LABELS`)* | variable | Selects which self-hosted runner executes `deploy-gpu-machine.yml` (`gcp-gpu`, `azure-gpu`, or `on-prem-gpu`; evaluated in `runs-on:`) |
| Repository | `BLOG_ADMIN_PASSWORD` | secret | Ghost owner login check after deploys |
| Repository | `METRICS_TOKEN` | secret | repo stats |
| `gpu` (branch `main` + reviewer `vitorecomp`) | `LITELLM_MASTER_KEY`, optional `HF_TOKEN`, `TUNNEL_SSH_PRIVATE_KEY`, `GPU_SSH_PRIVATE_KEY` | secret | LiteLLM/Harness API key, Hugging Face token, reverse-SSH private key, and non-GCP GPU SSH key (synced from gitignored `development/.env` via `gh` by `development/scripts/setup.sh`) |
| `gpu` | `ENABLE_REVERSE_TUNNELS`, `TUNNEL_SSH_HOST`, `TUNNEL_SSH_USER`, `TUNNEL_SSH_PORT`, `TUNNEL_KNOWN_HOSTS`, `TUNNEL_BIND_ADDRESS`, `REMOTE_LITELLM_PORT`, `REMOTE_HARNESS_PORT`, optional `GPU_TARGET_MODE` | variable | Reverse-tunnel destination/ports and runner target mode synced by `development/scripts/setup.sh` (model & CPU-offload settings live directly in `development/gpu-dev-machine/compose.yml`; full reference in [`development/README.md`](../development/README.md)) |
| `blog-prod`, `taiga-prod` (branch `main` only) | `DEPLOY_HOST`, `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS` | secret | VM address, per-stack deploy key (`~/.ssh/blog_deploy`, `~/.ssh/taiga_deploy`), and pinned VM host key |
| `blog-prod`, `taiga-prod` | `DEPLOY_USER` | variable | `deploy` |
| `blog-prod` | `BLOG_ADMIN_EMAIL` | secret | Ghost owner email check |
| `taiga-prod` | `TAIGA_DB_HOST`, `TAIGA_DB_USER`, `TAIGA_DB_PASSWORD`, `TAIGA_ADMIN_PASSWORD`, `TAIGA_ADMIN_EMAIL` | secret | Neon credentials (migrations, Secret Manager, the VM's backup `.env`); admin email & password (Secret Manager + login check) |
| `taiga-prod` | `TAIGA_DB_NAME`, optional `TAIGA_ADMIN_USER` (default `admin`) | variable | Neon database name; admin username |

`TAIGA_SECRET_KEY` lives only in Secret Manager (`taiga-secret-key`, read by the deploy job). Other app secrets
live only on the VM in `/opt/stacks/<stack>/.env` (mode 0600, created by `deploy_stack.py --init-env`, included in
the encrypted restic backups). The blog image is public-safe (Ghost + theme from a public repo); make the GHCR
package `personal-blog` public once (Package settings → Change visibility) so it never counts against the
private-package storage/transfer quota.

## 4. Local equivalents

```bash
python3 cloud/scripts/deploy_stack.py --stack edge --host deploy@<vm> --identity-file ~/.ssh/taiga_deploy
# blog: restart on the image already in the VM .env (new images come from the workflow's build job)
python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@<vm> --identity-file ~/.ssh/blog_deploy --skip-pull
# Taiga from a workstation (gcloud logged in as a project owner; GCP_PROJECT_ID / TAIGA_* loaded from root .env)
TAIGA_DB_HOST=... TAIGA_DB_USER=... TAIGA_DB_PASSWORD=... TAIGA_ADMIN_PASSWORD=... cloud/taiga/deploy-cloudrun.sh
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<vm> --identity-file ~/.ssh/taiga_deploy
```
