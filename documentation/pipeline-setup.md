# Pipeline & CI/CD Setup

How changes reach production. No cloud credentials live in GitHub: Terraform runs from a workstation
([vm-provisioning.md](./vm-provisioning.md)), deploys go over SSH to the VM, and the VM deploys Taiga to Cloud
Run with its own service account.

## 1. Flows

| What changes | Path to production |
| :--- | :--- |
| `vitorecomp/nobuffer-site`, `vitorecomp/personal-portifolio` | Vercel Git integration builds and deploys every push to the production branch. Nothing in this repo. |
| `vitorecomp/personal-blog` (Ghost theme/image) | Its `trigger-deploy.yml` sends `repository_dispatch: deploy-personal-blog` with `client_payload.sha` → [`deploy-blog.yml`](../.github/workflows/deploy-blog.yml) |
| `cloud/personal-blog/**`, `cloud/edge/**` here | push to `main` → `deploy-blog.yml` |
| `cloud/taiga/**`, `cloud/edge/**` here | push to `main` → [`deploy-taiga.yml`](../.github/workflows/deploy-taiga.yml) |
| `cloud/infra/**` | CI validates only; apply by hand |

Both deploy workflows share the `deploy-gcp-vm` concurrency group (one VM) and first deploy the edge stack.
They run only when the repository variables `BLOG_DEPLOY_ENABLED` / `TAIGA_DEPLOY_ENABLED` are `true`.

## 2. Workflows

| Workflow | Purpose |
| :--- | :--- |
| [`ci.yml`](../.github/workflows/ci.yml) | Secret scan (files + full history), Python syntax and `--dry-run` checks, `terraform fmt -check` / `validate` for `gcp-taiga` and `oci-blog`, stack validation (`docker compose config`, `caddy validate`, `bash -n`). |
| [`deploy-blog.yml`](../.github/workflows/deploy-blog.yml) | SSH → `deploy_stack.py --stack edge` then `--stack personal-blog` (rsync, app repo checkout at `APP_REF`, `compose build/up --wait`, recreate drifted images, HTTPS check, Ghost owner check). |
| [`deploy-taiga.yml`](../.github/workflows/deploy-taiga.yml) | SSH → edge, then `deploy_stack.py --stack taiga --sync-env TAIGA_DB_*` which runs `cloud/taiga/deploy-cloudrun.sh` on the VM: build (skipped if already in Artifact Registry), migrations against Neon, Secret Manager sync, Cloud Run revision; then HTTPS + admin login checks. |
| [`deploy-nginx-sites.yml`](../.github/workflows/deploy-nginx-sites.yml) | Nginx vhosts for a separate server (unrelated to the stacks above). |
| [`update-repo-stats.yml`](../.github/workflows/update-repo-stats.yml) | Weekly refresh of `workspace/documentation/repo_stats.csv`. |

## 3. Secrets and variables

| Where | Name | Kind | Purpose |
| :--- | :--- | :--- | :--- |
| Repository | `BLOG_DEPLOY_ENABLED`, `TAIGA_DEPLOY_ENABLED` | variable | deploy gates (job-level `if:` can only read repository variables) |
| Repository | `BLOG_ADMIN_PASSWORD` | secret | Ghost owner login check after deploys |
| Repository | `METRICS_TOKEN` | secret | repo stats |
| Repository | `HOST`, `USERNAME`, `KEY` | secret | Nginx server deploy |
| `blog-prod`, `taiga-prod` (branch `main` only) | `DEPLOY_HOST`, `DEPLOY_SSH_KEY` | secret | VM address and per-stack deploy key (`~/.ssh/blog_deploy`, `~/.ssh/taiga_deploy`) |
| `blog-prod`, `taiga-prod` | `DEPLOY_KNOWN_HOSTS`, `DEPLOY_USER` | variable | pinned VM host key, `deploy` |
| `blog-prod` | `BLOG_ADMIN_EMAIL` | variable | Ghost owner check |
| `taiga-prod` | `TAIGA_DB_HOST`, `TAIGA_DB_USER`, `TAIGA_DB_PASSWORD`, `TAIGA_ADMIN_PASSWORD` | secret | Neon credentials synced into the VM `.env`; admin login check |
| `taiga-prod` | `TAIGA_DB_NAME`, `TAIGA_ADMIN_EMAIL` | variable | Neon database name; admin email |

App secrets otherwise live only on the VM in `/opt/stacks/<stack>/.env` (mode 0600, created by
`deploy_stack.py --init-env`, included in the encrypted restic backups).

## 4. Local equivalents

```bash
python3 cloud/scripts/deploy_stack.py --stack edge --host deploy@<vm> --identity-file ~/.ssh/taiga_deploy
python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@<vm> --identity-file ~/.ssh/blog_deploy --app-ref main
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<vm> --identity-file ~/.ssh/taiga_deploy
```
