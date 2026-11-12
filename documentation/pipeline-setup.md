# Pipeline & CI/CD Setup

How changes reach production. Everything heavy (image builds, Taiga migrations, the Cloud Run rollout) runs on
GitHub-hosted runners, so the e2-micro VM only does light SSH steps (rsync, `compose pull`/`up`). No cloud keys
live in GitHub: the Taiga job impersonates `github-deployer@personal-project-514501` through **Workload Identity
Federation** (only this repo, on `main`, in the `taiga-prod` environment), and Terraform still runs only from a
workstation ([vm-provisioning.md](./vm-provisioning.md)).

## 1. Flows

| What changes | Path to production |
| :--- | :--- |
| `vitorecomp/nobuffer-site`, `vitorecomp/personal-portifolio` | Vercel Git integration builds and deploys every push to the production branch. Nothing in this repo. |
| `vitorecomp/personal-blog` (Ghost theme/image) | Its `trigger-deploy.yml` sends `repository_dispatch: deploy-personal-blog` with `client_payload.sha` → [`deploy-blog.yml`](../.github/workflows/deploy-blog.yml) |
| `cloud/personal-blog/**`, `cloud/edge/**`, `cloud/scripts/{deploy_stack,backup_stack,seed_ghost_admin}.py`, the workflow | push to `main` → `deploy-blog.yml` |
| `cloud/taiga/**`, `cloud/edge/**`, `cloud/scripts/{deploy_stack,backup_stack,seed_taiga_admin}.py`, the workflow | push to `main` → [`deploy-taiga.yml`](../.github/workflows/deploy-taiga.yml) |
| `cloud/infra/**` | CI validates only; apply by hand |

Both deploy workflows share the `deploy-gcp-vm` concurrency group (one VM) and refresh the edge stack in their VM job.
They run only when the repository variables `BLOG_DEPLOY_ENABLED` / `TAIGA_DEPLOY_ENABLED` are `true`.

## 2. Workflows

| Workflow | Purpose |
| :--- | :--- |
| [`ci.yml`](../.github/workflows/ci.yml) | Secret scan (files + full history), Python syntax and `--dry-run` checks, `terraform fmt -check` / `validate` for `gcp-taiga` and `oci-blog`, stack validation (`docker compose config`, `caddy validate`, `bash -n`). |
| [`deploy-blog.yml`](../.github/workflows/deploy-blog.yml) | **build** (runner): checks out `vitorecomp/personal-blog` at the dispatched SHA (default `main`), validates the theme, builds and pushes `ghcr.io/vitorecomp/personal-blog:<sha>`. **deploy** (SSH): `deploy_stack.py --stack edge`, then `--stack personal-blog --sync-env GHOST_IMAGE` (digest-pinned image into the VM `.env`, `compose pull` with a throwaway login using the job's `GITHUB_TOKEN`, `up --wait`, HTTPS check, Ghost owner check). |
| [`deploy-taiga.yml`](../.github/workflows/deploy-taiga.yml) | **cloud-run** (runner, WIF): [`cloud/taiga/deploy-cloudrun.sh`](../cloud/taiga/deploy-cloudrun.sh) builds the image (skipped if this build context is already in Artifact Registry), runs migrations against Neon, syncs the DB/admin passwords into Secret Manager and rolls out a Cloud Run revision. **vm** (SSH): edge stack, then `deploy_stack.py --stack taiga --sync-env TAIGA_DB_*` (keeps the VM's backup credentials current), HTTPS + admin login checks through the VM. |
| [`deploy-nginx-sites.yml`](../.github/workflows/deploy-nginx-sites.yml) | Nginx vhosts for a separate server (unrelated to the stacks above). |
| [`update-repo-stats.yml`](../.github/workflows/update-repo-stats.yml) | Weekly refresh of `workspace/documentation/repo_stats.csv`. |

## 3. Secrets and variables

| Where | Name | Kind | Purpose |
| :--- | :--- | :--- | :--- |
| Repository | `BLOG_DEPLOY_ENABLED`, `TAIGA_DEPLOY_ENABLED` | variable | deploy gates (job-level `if:` can only read repository variables) |
| Repository | `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA` | variable | `terraform output github_wif_provider` / `github_deployer_email` in `cloud/infra/envs/gcp-taiga` (identifiers, not credentials) |
| Repository | `BLOG_ADMIN_PASSWORD` | secret | Ghost owner login check after deploys |
| Repository | `METRICS_TOKEN` | secret | repo stats |
| Repository | `HOST`, `USERNAME`, `KEY` | secret | Nginx server deploy |
| `blog-prod`, `taiga-prod` (branch `main` only) | `DEPLOY_HOST`, `DEPLOY_SSH_KEY` | secret | VM address and per-stack deploy key (`~/.ssh/blog_deploy`, `~/.ssh/taiga_deploy`) |
| `blog-prod`, `taiga-prod` | `DEPLOY_KNOWN_HOSTS`, `DEPLOY_USER` | variable | pinned VM host key, `deploy` |
| `blog-prod` | `BLOG_ADMIN_EMAIL` | variable | Ghost owner check |
| `taiga-prod` | `TAIGA_DB_HOST`, `TAIGA_DB_USER`, `TAIGA_DB_PASSWORD`, `TAIGA_ADMIN_PASSWORD` | secret | Neon credentials (migrations, Secret Manager, the VM's backup `.env`); admin password (Secret Manager + login check) |
| `taiga-prod` | `TAIGA_DB_NAME`, `TAIGA_ADMIN_EMAIL`, optional `TAIGA_ADMIN_USER` (default `admin`) | variable | Neon database name; admin email / user |

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
# Taiga from a workstation (gcloud logged in as a project owner); TAIGA_* as in the taiga-prod environment
TAIGA_DB_HOST=... TAIGA_DB_USER=... TAIGA_DB_PASSWORD=... TAIGA_ADMIN_PASSWORD=... cloud/taiga/deploy-cloudrun.sh
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<vm> --identity-file ~/.ssh/taiga_deploy
```
