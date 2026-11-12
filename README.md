# personal-infra

Central repository for automatically provisioning, configuring, and maintaining all personal infrastructure across cloud environments, home server, Linux machines, and local development workspaces.

## Repository Structure

```text
personal-infra/
├── .agents/skills/           # Agent skills (e.g., taiga REST API skill & CLI)
├── .github/workflows/        # CI validation, deploys (images built on runners; Taiga via WIF), Nginx deploy, repo stats
├── documentation/            # Architecture, provisioning, pipeline, backup and workspace docs
├── cloud/                    # Cloud infrastructure and workload deployments
│   ├── infra/                # Terraform, applied by hand: gcp-taiga (VM + Taiga Cloud Run), oci-blog (spare OCI VM)
│   ├── edge/                 # Shared Caddy on the VM: TLS for blog. and taiga. (Taiga proxied to Cloud Run)
│   ├── nobuffer-site/        # Nginx reverse-proxy & maintenance page (the site itself is on Vercel)
│   ├── personal-blog/        # Ghost + local MySQL compose stack for the VM
│   ├── taiga/                # Taiga image + Cloud Run deploy script (built/deployed from GitHub Actions)
│   └── scripts/              # bootstrap / deploy / backup / OCI retry scripts, Ghost & Taiga seeders
├── home-server/              # Home server / self-hosted services and maintenance (TBD)
├── linux/                    # Linux OS bootstrap, packages, and system configuration (TBD)
└── workspace/                # Local ~/workspace repository inventory and synchronization
```

| Directory | Responsibility | Status |
| :--- | :--- | :--- |
| **[`documentation/`](./documentation)** | Guides: [Cloud Architecture](./documentation/cloud-architecture.md), [VM Provisioning](./documentation/vm-provisioning.md), [Pipeline Setup](./documentation/pipeline-setup.md), [Backup & Restore](./documentation/backup-restore.md), [Workspace Management](./documentation/workspace-setup.md). | Active |
| **`cloud/`** | Provisioning and maintaining cloud resources, networking, and hosted workloads (`nobuffer-site`, `personal-portifolio`, `personal-blog`, `taiga`). | Active |
| **`home-server/`** | Self-hosted services, container stacks, backups, and home lab automation. | _Planned (to be defined)_ |
| **`linux/`** | Workstation/system setup, packages, dotfiles, and OS-level maintenance scripts. | _Planned (to be defined)_ |
| **`workspace/`** | Automated discovery, organization, and cloning of GitHub repositories into `~/workspace`. | Active |

---

## Modules

### 1. `cloud/`

| Site | Runs on | Defined in |
| :--- | :--- | :--- |
| `vitorx86.dev`, `www` | Vercel (Git integration on `vitorecomp/nobuffer-site`) | app repo (`vercel.json`) |
| `me.`, `cases.` | Vercel (Git integration on `vitorecomp/personal-portifolio`) | app repo (`vercel.json`) |
| `blog.` | GCE e2-micro VM `personal-host` (free tier): edge Caddy → Ghost 5.130 → local MySQL 8.0 | [`cloud/edge`](./cloud/edge), [`cloud/personal-blog`](./cloud/personal-blog) |
| `taiga.` | Cloud Run `taiga` (free tier) via the edge Caddy; database on Neon (Postgres 15); uploads in GCS | [`cloud/taiga`](./cloud/taiga) |

DNS is on Cloudflare (DNS-only records, managed by hand). Details: [cloud-architecture.md](./documentation/cloud-architecture.md).

- **Terraform (applied by hand, never in CI)**: [`cloud/infra/envs/gcp-taiga`](./cloud/infra/envs/gcp-taiga) (VM, Taiga Cloud Run + Artifact Registry + Secret Manager + media bucket, backup bucket) and [`cloud/infra/envs/oci-blog`](./cloud/infra/envs/oci-blog) (spare OCI A1 VM, still being acquired by a retry loop). Runbook: [vm-provisioning.md](./documentation/vm-provisioning.md).
- **Stacks**: `cloud/<stack>/` with `stack.json` + `.env.example` (+ `compose.yml` when it runs on the VM). Nothing is built on the VM: the blog image is built in CI and pulled from GHCR, Taiga is built and deployed to Cloud Run from CI. Secrets live only in `/opt/stacks/<stack>/.env` on the VM, Secret Manager (Taiga runtime) and the GitHub environments.
- **Scripts** (stdlib Python / bash, all with `--dry-run`):
  [`bootstrap_vm.py`](./cloud/scripts/bootstrap_vm.py) (host setup, `--check` for drift),
  [`deploy_stack.py`](./cloud/scripts/deploy_stack.py) (rsync + `.env` preflight + `compose pull`/`up --wait` + HTTPS check; used by CI and locally),
  [`backup_stack.py`](./cloud/scripts/backup_stack.py) (DB dumps incl. remote Neon, volumes, GCS buckets → restic in `gs://vitorx86-backups`),
  [`tf_apply_retry.sh`](./cloud/scripts/tf_apply_retry.sh) (OCI capacity retry loop),
  [`configure_ai_spend_cap.py`](./cloud/scripts/configure_ai_spend_cap.py).

```bash
python3 cloud/scripts/bootstrap_vm.py --host ubuntu@<ip> --provider gce --deploy-pubkey-file ~/.ssh/blog_deploy.pub --check
python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@<ip> --identity-file ~/.ssh/blog_deploy --dry-run
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<ip> --identity-file ~/.ssh/taiga_deploy      # VM side only (backup .env); Cloud Run deploys: cloud/taiga/deploy-cloudrun.sh in deploy-taiga.yml
ssh deploy@<ip> 'python3 /opt/stacks/.ops/backup_stack.py --stack taiga --restore-test'
python3 cloud/scripts/configure_ai_spend_cap.py <project_id> --amount 1200 --services all --dry-run
```

### 2. `home-server/`
_Details to be added._ Will hold configurations, service definitions, and maintenance workflows for the home server.

### 3. `linux/`
_Details to be added._ Will hold scripts and configuration files to bootstrap and maintain Linux environments.

### 4. `workspace/`
Manages the local `~/workspace` directory hierarchy based on a tracked inventory of GitHub repositories.

- **Inventory ([`repo_stats.csv`](./workspace/documentation/repo_stats.csv))**: Tracks repository metadata (`name`, `link`, `ssh link`, `last updated`, `is a fork`) alongside manual curation fields (`folder`, `is-custom`, `is-template`).
- **Update Inventory ([`update_repo_stats.py`](./workspace/scripts/update_repo_stats.py))**: Queries the GitHub API for `vitorecomp` repositories, updates metadata in `repo_stats.csv` while preserving manual columns (`folder`, `is-custom`, `is-template`), and orders all rows by `last updated` descending.
  ```bash
  # Optional: export GITHUB_TOKEN or METRICS_TOKEN to include private repos / avoid rate limits
  python3 workspace/scripts/update_repo_stats.py
  ```
- **Sync Workspace ([`sync_workspace_repos.py`](./workspace/scripts/sync_workspace_repos.py))**: Organizes already-cloned repositories into `~/workspace/<folder>/<name>` and clones any missing repositories that have a target `folder` assigned in `repo_stats.csv`.
  ```bash
  # Preview moves and clones without modifying the filesystem
  python3 workspace/scripts/sync_workspace_repos.py --dry-run

  # Execute workspace synchronization
  python3 workspace/scripts/sync_workspace_repos.py --jobs 4
  ```
- **Validate Repositories Pushed ([`validate_repos_pushed.py`](./workspace/scripts/validate_repos_pushed.py))**: Scans `~/workspace` (or a specific subfolder/category) and checks that every Git repository has a configured remote, a clean working tree, and all local commits pushed.
  ```bash
  # Validate all repositories in ~/workspace
  python3 workspace/scripts/validate_repos_pushed.py

  # Validate a specific category folder (e.g., ~/workspace/personal)
  python3 workspace/scripts/validate_repos_pushed.py personal
  ```
- **Scan Repository Secrets & Pre-Commit Guard ([`scan_repo_secrets.py`](./workspace/scripts/scan_repo_secrets.py))**: Scans tracked files, staged index changes, and full Git commit history for leaked keys, cloud credentials, API tokens, and unignored secret files, and idempotently installs a local Git `pre-commit` hook.
  ```bash
  # Audit tracked files and full Git commit history
  python3 workspace/scripts/scan_repo_secrets.py --history

  # Preview and install the local Git pre-commit secret-scanning hook
  python3 workspace/scripts/scan_repo_secrets.py --install-hook --dry-run
  python3 workspace/scripts/scan_repo_secrets.py --install-hook
  ```
- **Enroll GitHub Repositories on Taiga ([`enroll_taiga_projects.py`](./workspace/scripts/enroll_taiga_projects.py))**: Idempotently enrolls GitHub repositories from `repo_stats.csv` as Scrum projects on `https://taiga.vitorx86.dev` and orders them with the most recently committed repository first.
  ```bash
  python3 workspace/scripts/enroll_taiga_projects.py --dry-run
  python3 workspace/scripts/enroll_taiga_projects.py
  ```
- **Taiga REST API CLI & Agent Skill ([`taiga_cli.py`](./.agents/skills/taiga/scripts/taiga_cli.py) / [`SKILL.md`](./.agents/skills/taiga/SKILL.md))**: Manages projects, Scrum sprints, user stories, tasks, issues, epics, and wiki pages via the Taiga REST API (`/api/v1`). Both Taiga scripts read their settings from the gitignored [`.agents/skills/taiga/.env`](./.agents/skills/taiga/.env.example) (mode 0600; falls back to the `taiga-admin-password` secret via `gcloud`).
  ```bash
  cp .agents/skills/taiga/.env.example .agents/skills/taiga/.env && chmod 600 .agents/skills/taiga/.env   # once, then fill it in
  python3 workspace/scripts/taiga_cli.py projects list
  python3 workspace/scripts/taiga_cli.py stories list personal-infra
  python3 workspace/scripts/taiga_cli.py stories create personal-infra --subject "Add feature" --points 3 --dry-run
  ```

---

## GitHub Actions Workflows

| Workflow | File | Trigger | Description |
| :--- | :--- | :--- | :--- |
| **CI Validation** | [`ci.yml`](./.github/workflows/ci.yml) | Push, PR, manual | Secret scan (files + history), Python syntax and `--dry-run` checks, `terraform fmt -check` / `validate` for every root (no plan/apply), stack validation (`docker compose config`, `caddy validate`, shell syntax). |
| **Deploy the Personal Blog (GCP VM)** | [`deploy-blog.yml`](./.github/workflows/deploy-blog.yml) | Push on `cloud/personal-blog/**`, `cloud/edge/**`, `deploy_stack.py`, `backup_stack.py`, `seed_ghost_admin.py` or the workflow; `repository_dispatch` (`deploy-personal-blog`); manual | Runner builds the Ghost image from `vitorecomp/personal-blog` and pushes it to GHCR; SSH to the VM: edge + blog pull/restart via `deploy_stack.py`. Gated by `BLOG_DEPLOY_ENABLED`; environment `blog-prod`. |
| **Deploy Taiga (Cloud Run)** | [`deploy-taiga.yml`](./.github/workflows/deploy-taiga.yml) | Push on `cloud/taiga/**`, `cloud/edge/**`, `deploy_stack.py`, `backup_stack.py`, `seed_taiga_admin.py` or the workflow; `repository_dispatch` (`deploy-taiga`); manual | Runner (keyless, Workload Identity Federation): `deploy-cloudrun.sh` (build, migrations against Neon, Secret Manager sync, Cloud Run revision); then SSH to the VM for the edge stack and Taiga's backup `.env`. Gated by `TAIGA_DEPLOY_ENABLED`; environment `taiga-prod`. |
| **Deploy the Nginx** | [`deploy-nginx-sites.yml`](./.github/workflows/deploy-nginx-sites.yml) | Push on `cloud/nobuffer-site/reverse-proxy/**`, manual | Copies Nginx reverse-proxy configs over SSH to a separate server, validates, reloads, Certbot. |
| **Update Workspace Repo Stats** | [`update-repo-stats.yml`](./.github/workflows/update-repo-stats.yml) | Weekly (Mon 06:00 UTC), manual | Refreshes [`repo_stats.csv`](./workspace/documentation/repo_stats.csv). |

### GitHub Secrets & Variables

- **Environments `blog-prod` / `taiga-prod`** (deployments from `main` only): secrets `DEPLOY_HOST`, `DEPLOY_SSH_KEY`; variables `DEPLOY_KNOWN_HOSTS`, `DEPLOY_USER`. `taiga-prod` also holds `TAIGA_DB_HOST` / `TAIGA_DB_USER` / `TAIGA_DB_PASSWORD` (Neon), `TAIGA_ADMIN_PASSWORD`, and the variables `TAIGA_DB_NAME`, `TAIGA_ADMIN_EMAIL` (optional `TAIGA_ADMIN_USER`, default `admin`); `blog-prod` holds `BLOG_ADMIN_EMAIL`.
- **Repository**: secret `BLOG_ADMIN_PASSWORD` (Ghost owner check after deploys), `METRICS_TOKEN` (repo stats), `HOST` / `USERNAME` / `KEY` (Nginx server); variables `BLOG_DEPLOY_ENABLED`, `TAIGA_DEPLOY_ENABLED`, `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA`.
- No cloud keys live in GitHub: Terraform runs from a workstation; the Taiga deploy impersonates `github-deployer` through Workload Identity Federation (this repo, `main`, `taiga-prod` only); the blog image goes to GHCR with the job's `GITHUB_TOKEN`.

---

## Core Principles

- **Idempotent Execution**: Scripts and provisioning workflows can be re-run safely at any time without unintended side effects.
- **Dry-Run Support**: Destructive or state-changing tools provide a `--dry-run` / preview mode before applying changes.
- **No Committed Secrets**: Credentials, tokens, and private keys are supplied strictly via environment variables or secret managers.

## License

Released under the [MIT License](./LICENSE).
