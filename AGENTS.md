# AGENTS.md

Instructions and context for AI coding agents working in `personal-infra`.

## Project Overview

`personal-infra` is the central automation repository responsible for provisioning, configuring, and maintaining all personal infrastructure for `vitorecomp`.

The repository is organized into four top-level domains:

1. **`cloud/`** — **Migrating** (see `documentation/migration-runbook.md`) from the legacy GCP stack (Global HTTPS LB, Cloud CDN, GCS static buckets, Cloud Run + Cloud SQL, Cloud Build; `cloud/infra/envs/prod`) to: `nobuffer-site` + `personal-portifolio` on Vercel, `personal-blog` (Ghost) on an OCI Always Free A1 VM and `taiga` on a GCE free-tier e2-micro VM. Both VMs are created by Terraform applied **by hand** (`cloud/infra/envs/{oci-blog,gcp-taiga}`, `documentation/vm-provisioning.md`), configured by `bootstrap_vm.py`, and run docker compose stacks (`cloud/{personal-blog,taiga}/compose.yml`, Caddy for TLS) deployed over SSH by `deploy_stack.py` (locally and from GitHub Actions). Also holds reverse-proxy configs.
2. **`home-server/`** — Home server workloads, self-hosted services, networking, and maintenance _(specification pending)_.
3. **`linux/`** — Linux system bootstrap, package installation, dotfiles, and OS configuration _(specification pending)_.
4. **`workspace/`** — Local `~/workspace` directory orchestration and GitHub repository synchronization.

> **Note for Agents:** `home-server/` and `linux/` will be specified incrementally by the user. Do not invent or scaffold opinionated tooling (e.g., Ansible, Nix, Docker Compose) inside those directories until the user defines the requirements for each domain.

---

## Current Repository Layout

```text
personal-infra/
├── README.md
├── AGENTS.md
├── LICENSE
├── documentation/
│   ├── README.md                           # Documentation index
│   ├── cloud-architecture.md               # GCP LB, CDN, GCS, Cloud Run & Cloud SQL architecture
│   ├── cloud-setup.md                      # GCP bootstrap, IAM, Terraform & DNS setup guide
│   ├── pipeline-setup.md                   # GitHub Actions, Cloud Build, SSH deploys & secrets/variables guide
│   ├── migration-runbook.md                # GCP -> Vercel + compose VMs: phases, cutover checklists, rollback
│   ├── vm-provisioning.md                  # Manual Terraform runbook for the VM roots (+ legacy prod destroy)
│   ├── backup-restore.md                   # restic backups of the compose stacks (GCS bucket) & restores
│   └── workspace-setup.md                  # Local ~/workspace inventory & sync documentation
├── .agents/skills/
│   └── taiga/
│       ├── SKILL.md                        # Agent skill definition for Taiga REST API management
│       └── scripts/
│           └── taiga_cli.py                # Canonical CLI for Taiga projects, sprints, stories, tasks, issues & wiki
├── .github/workflows/
│   ├── ci.yml                              # Secret scan, Python syntax/dry-run checks, Terraform fmt/validate (no apply), compose/Caddy validation
│   ├── deploy-blog.yml                     # SSH deploy of cloud/personal-blog to the OCI VM (gated by BLOG_DEPLOY_ENABLED)
│   ├── deploy-taiga.yml                    # SSH deploy of cloud/taiga to the GCE VM (gated by TAIGA_DEPLOY_ENABLED)
│   ├── build-website.yml                   # Fetches nobuffer-site and submits Cloud Build
│   ├── build-portfolio.yml                 # Fetches personal-portifolio and submits Cloud Build
│   ├── build-blog.yml                      # LEGACY: personal-blog Cloud Build -> Cloud Run (no push trigger)
│   ├── build-taiga.yml                     # LEGACY: cloud/taiga Cloud Build -> Cloud Run (no push trigger)
│   ├── deploy-nginx-sites.yml              # Deploys reverse-proxy vhosts to server via SSH
│   └── update-repo-stats.yml               # Scheduled/manual sync of repo_stats.csv
├── mise.toml                               # Workstation tool pins (terraform, cloud-sql-proxy)
├── cloud/                                  # Cloud infrastructure and deployment automation
│   ├── infra/
│   │   ├── modules/gce-vm/                 # GCE VM + dedicated VPC/firewall + static IP + runtime SA
│   │   ├── modules/oci-vm/                 # OCI A1 VM + VCN/security list + reserved IP
│   │   ├── modules/load-balancer/          # LEGACY GCP LB/CDN/Cloud Run/Cloud SQL (destroyed in Phase 5)
│   │   ├── envs/gcp-taiga/                 # Taiga VM (personal-project-514501) + shared backup bucket; applied by hand
│   │   ├── envs/oci-blog/                  # Blog VM (compartment vitorecomp); applied by hand
│   │   └── envs/prod/                      # LEGACY compute-bench stack (frozen)
│   ├── nobuffer-site/
│   │   ├── cloudbuild.yaml                 # LEGACY Cloud Build pipeline (site moves to Vercel)
│   │   ├── maintenance/                    # Containerized static maintenance page
│   │   └── reverse-proxy/                  # Nginx vhost configs (*.vitorx86.dev)
│   ├── personal-portifolio/
│   │   └── cloudbuild.yaml                 # LEGACY Cloud Build static export (site moves to Vercel)
│   ├── personal-blog/
│   │   ├── compose.yml, Caddyfile          # Caddy -> Ghost (built from vitorecomp/personal-blog on the VM) -> MySQL 8.0
│   │   ├── .env.example, stack.json        # VM .env template & deploy/backup metadata
│   │   └── cloudbuild.yaml                 # LEGACY Cloud Run pipeline
│   ├── taiga/
│   │   ├── Dockerfile                      # taiga-front + taiga-back (pinned 6.10.3 / 6.10.2) + nginx container
│   │   ├── nginx.conf                      # Nginx gateway routing /, /api, /admin, /static, /media on :8080
│   │   ├── docker-entrypoint.sh            # Idempotent DB migrations, template load & superuser seed
│   │   ├── compose.yml, Caddyfile          # Production stack on the GCE VM: Caddy -> Taiga -> Postgres 15
│   │   ├── .env.example, stack.json        # VM .env template & deploy/backup metadata
│   │   ├── compose.local.yml               # Local dev compose stack (127.0.0.1:8080)
│   │   └── cloudbuild.yaml                 # LEGACY Cloud Run pipeline
│   └── scripts/
│       ├── bootstrap_vm.py                 # Idempotent host setup over SSH (Docker, deploy user, swap, sshd, firewall, backup timers)
│       ├── deploy_stack.py                 # rsync + remote .env preflight + compose up --wait + HTTPS check (CI & local)
│       ├── backup_stack.py                 # Runs on the VM: DB dump + volumes -> restic in gs://vitorx86-backups
│       ├── migrate_gcp_data.py             # TEMPORARY: Cloud SQL/GCS -> VMs (archive/export/import/verify/copy-secrets)
│       ├── tf_apply_retry.sh               # Retries plan+apply on OCI 'Out of host capacity' (refuses destructive plans)
│       ├── download_nobuffer_site.py       # LEGACY: clones nobuffer-site and optionally deploys via Cloud Build
│       ├── download_personal_portifolio.py # LEGACY: clones personal-portifolio and optionally deploys via Cloud Build
│       ├── download_personal_blog.py       # LEGACY: clones personal-blog and optionally deploys via Cloud Build
│       ├── deploy_taiga.py                 # LEGACY: validates cloud/taiga and deploys to Cloud Run
│       ├── seed_ghost_admin.py             # Idempotently seeds/verifies the Ghost owner (--connect-ip/--insecure for VMs)
│       ├── seed_taiga_admin.py             # Idempotently verifies Taiga API & admin login (--connect-ip/--insecure for VMs)
│       └── configure_ai_spend_cap.py       # Idempotently configures GCP Cloud Billing Spend Cap budgets for AI services
├── home-server/                            # (Planned) Home server setup and maintenance
├── linux/                                  # (Planned) Linux workstation/system configuration
└── workspace/                              # Local repository management
    ├── documentation/
    │   └── repo_stats.csv                  # Source-of-truth repo inventory & folder mapping
    └── scripts/
        ├── update_repo_stats.py            # Syncs GitHub repo metadata into repo_stats.csv
        ├── sync_workspace_repos.py         # Moves/clones repos into ~/workspace/<folder>/<name>
        ├── validate_repos_pushed.py        # Validates whether git repos in a folder are clean and pushed
        ├── scan_repo_secrets.py            # Scans repos/history for leaked keys/secrets & installs pre-commit hook
        ├── enroll_taiga_projects.py        # Idempotently enrolls GitHub repos from repo_stats.csv as Taiga projects
        └── taiga_cli.py                    # Wrapper CLI delegating to .agents/skills/taiga/scripts/taiga_cli.py
```

---

## Engineering Conventions & Guardrails

### 1. Idempotency & Safety First
- Every script, playbook, or provisioning command must be **idempotent**—running it multiple times must converge on the same state without duplicating resources or corrupting local changes.
- Any script that mutates the filesystem, system packages, network state, or external infrastructure **must** support a `--dry-run` flag (or equivalent plan/check mode).
- Always test state-changing scripts with `--dry-run` before running them for real.

### 2. Preserve User-Curated State
- When updating partially automated data files (such as `documentation/repo_stats.csv`), never overwrite manual columns (`folder`, `is-custom`, `is-template`); rows in `repo_stats.csv` are sorted by `last updated` descending.
- When moving or syncing local directories (such as `~/workspace`), never delete or overwrite existing repositories or untracked local folders that are omitted from configuration.

### 3. Secrets & Credentials
- **Never** hardcode or commit API tokens, SSH keys, passwords, `.env` files, `.tfvars` files, `.tfstate` files, or sensitive host/IP details.
- Read credentials exclusively from environment variables (e.g., `GITHUB_TOKEN`, `METRICS_TOKEN`, `GCS_BUCKET_NAME`, `GCS_PORTFOLIO_BUCKET_NAME`, `BLOG_URL`) or external secret stores, with graceful fallbacks when unauthenticated execution is possible.

### 4. Terraform & VM Stacks
- **Never add a CI workflow that runs `terraform plan/apply`** or stores cloud credentials in GitHub; VM roots are applied by hand (`documentation/vm-provisioning.md`), CI only runs `fmt`/`validate`. Keep `prevent_destroy`, `deletion_protection` and the image `ignore_changes` guards.
- Compose stacks: only Caddy publishes ports; every volume has an explicit `name:`; never `docker compose down -v`; pin image tags.
- VM app secrets live only in `/opt/stacks/<stack>/.env` (mode 0600). CI never writes it; `deploy_stack.py` only checks key names. Add new keys to `.env.example` (`__generate__` / `__required__` placeholders).
- New or renamed scripts in `cloud/scripts/` need a matching `--dry-run` line in `.github/workflows/ci.yml`.

### 5. Code Style & Dependencies
- **Python**: Target Python 3.10+ using standard library modules (`pathlib`, `argparse`, `csv`, `json`, `subprocess`, `urllib.request`, `concurrent.futures`) whenever possible to keep bootstrap scripts zero-dependency. Use type annotations on all function signatures.
- **Paths**: Resolve paths relative to script locations (`Path(__file__).resolve()`) rather than relying on the caller's working directory, and allow CLI overrides via `argparse`.

### 6. Documentation Hygiene
- When a new domain folder (`cloud/`, `home-server/`, `linux/`, `workspace/`) is populated or updated, update both `README.md` and `AGENTS.md` with its architecture, entrypoints, and verification commands.

---

## Common Commands

```bash
# Preview downloading/updating workloads and Cloud Build submission (safe, read-only)
python3 cloud/scripts/download_nobuffer_site.py --deploy --bucket <nobuffer_bucket> --dry-run
python3 cloud/scripts/download_personal_portifolio.py --deploy --bucket <portfolio_bucket> --dry-run
python3 cloud/scripts/download_personal_blog.py --deploy --dry-run
python3 cloud/scripts/deploy_taiga.py --deploy --dry-run
python3 cloud/scripts/configure_ai_spend_cap.py <project_id> --amount 1200 --services all --dry-run

# VM stacks (Terraform itself is run by hand: documentation/vm-provisioning.md)
python3 cloud/scripts/bootstrap_vm.py --host ubuntu@<ip> --provider oracle --deploy-pubkey-file ~/.ssh/blog_deploy.pub --backup-stack personal-blog --dry-run
python3 cloud/scripts/bootstrap_vm.py --host ubuntu@<ip> --provider gce --deploy-pubkey-file ~/.ssh/taiga_deploy.pub --swap-gb 3 --backup-stack taiga --check
python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@<ip> --dry-run
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<ip> --init-env
python3 cloud/scripts/backup_stack.py --stack-dir cloud/taiga --dry-run
python3 cloud/scripts/migrate_gcp_data.py all --stack personal-blog --host deploy@<ip> --confirm-overwrite --dry-run
cloud/scripts/tf_apply_retry.sh --env oci-blog --dry-run
docker compose -f cloud/taiga/compose.yml --env-file cloud/taiga/.env.example config -q
terraform -chdir=cloud/infra/envs/gcp-taiga init -backend=false && terraform -chdir=cloud/infra/envs/gcp-taiga validate

# LEGACY (until each cutover): download or update repositories into cloud/<project>/repo
python3 cloud/scripts/download_nobuffer_site.py
python3 cloud/scripts/download_personal_portifolio.py
python3 cloud/scripts/download_personal_blog.py

# Refresh GitHub repository metadata in repo_stats.csv
python3 workspace/scripts/update_repo_stats.py

# Preview ~/workspace organization and cloning (safe, read-only)
python3 workspace/scripts/sync_workspace_repos.py --dry-run

# Apply ~/workspace organization and clone missing assigned repositories
python3 workspace/scripts/sync_workspace_repos.py --jobs 4

# Validate whether all git repositories in ~/workspace (or a specific folder) are clean and pushed
python3 workspace/scripts/validate_repos_pushed.py
python3 workspace/scripts/validate_repos_pushed.py personal

# Scan repository & git history for committed keys/secrets and install the pre-commit hook
python3 workspace/scripts/scan_repo_secrets.py --history
python3 workspace/scripts/scan_repo_secrets.py --install-hook --dry-run
python3 workspace/scripts/scan_repo_secrets.py --install-hook

# Preview or enroll GitHub repositories from repo_stats.csv as projects on Taiga
python3 workspace/scripts/enroll_taiga_projects.py --dry-run
TAIGA_ADMIN_PASSWORD=<password> python3 workspace/scripts/enroll_taiga_projects.py personal

# Manage Taiga projects, sprints, user stories, tasks, issues, epics, and wiki pages via CLI
python3 workspace/scripts/taiga_cli.py projects list
python3 workspace/scripts/taiga_cli.py stories list personal-infra
python3 workspace/scripts/taiga_cli.py stories create personal-infra --subject "My Story" --points 3 --dry-run
```
