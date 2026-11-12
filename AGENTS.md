# AGENTS.md

Instructions and context for AI coding agents working in `personal-infra`.

## Project Overview

`personal-infra` is the central automation repository responsible for provisioning, configuring, and maintaining all personal infrastructure for `vitorecomp`.

The repository is organized into four top-level domains:

1. **`cloud/`** — `nobuffer-site` + `personal-portifolio` on Vercel (Git integration on their repos); `personal-blog` (Ghost + local MySQL) on the GCE free-tier e2-micro VM `personal-host` behind a shared Caddy (`cloud/edge`); `taiga` on Cloud Run free tier (built and deployed from GitHub Actions by `cloud/taiga/deploy-cloudrun.sh` as `github-deployer` via Workload Identity Federation, database on Neon Postgres 15, media in GCS). The VM never builds images: the Ghost image is built in CI and pulled from GHCR. Terraform in `cloud/infra/envs/{gcp-taiga,oci-blog}` is applied from a workstation, never in CI (`documentation/vm-provisioning.md`); `oci-blog` is a spare OCI A1 VM still being acquired by `tf_apply_retry.sh` on the VM. DNS is on Cloudflare. Also holds reverse-proxy configs for a separate Nginx server.
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
│   ├── pipeline-setup.md                   # GitHub Actions, SSH deploys & secrets/variables guide
│   ├── migration-runbook.md                # History: the 2026-11 move off the compute-bench GCP stack (completed)
│   ├── vm-provisioning.md                  # Manual Terraform runbook for the VM roots
│   ├── backup-restore.md                   # restic backups of the compose stacks (GCS bucket) & restores
│   └── workspace-setup.md                  # Local ~/workspace inventory & sync documentation
├── .agents/skills/
│   └── taiga/
│       ├── SKILL.md                        # Agent skill definition for Taiga REST API management
│       └── scripts/
│           └── taiga_cli.py                # Canonical CLI for Taiga projects, sprints, stories, tasks, issues & wiki
├── .github/workflows/
│   ├── ci.yml                              # Secret scan, Python syntax/dry-run checks, Terraform fmt/validate (no apply), compose/Caddy validation
│   ├── deploy-blog.yml                     # Runner builds Ghost -> GHCR; SSH: edge + blog pull/restart on the GCP VM (gated by BLOG_DEPLOY_ENABLED)
│   ├── deploy-taiga.yml                    # Runner (WIF): Taiga build/migrate/Cloud Run; SSH: edge + Taiga backup .env (gated by TAIGA_DEPLOY_ENABLED)
│   ├── deploy-nginx-sites.yml              # Deploys reverse-proxy vhosts to server via SSH
│   └── update-repo-stats.yml               # Scheduled/manual sync of repo_stats.csv
├── mise.toml                               # Workstation tool pins (terraform, cloud-sql-proxy)
├── cloud/                                  # Cloud infrastructure and deployment automation
│   ├── edge/                               # Shared Caddy (TLS + routing) for every stack on the GCP VM
│   ├── infra/
│   │   ├── modules/gce-vm/                 # GCE VM + dedicated VPC/firewall + static IP + runtime SA
│   │   ├── modules/oci-vm/                 # OCI A1 VM + VCN/security list + reserved IP
│   │   ├── envs/gcp-taiga/                 # VM + Taiga Cloud Run/AR/secrets/media bucket + backup bucket (personal-project-514501); applied by hand
│   │   └── envs/oci-blog/                  # Spare OCI A1 VM (capacity retry loop); applied by hand, not used yet
│   ├── nobuffer-site/                      # The site itself deploys to Vercel from its own repo
│   │   ├── maintenance/                    # Containerized static maintenance page
│   │   └── reverse-proxy/                  # Nginx vhost configs (*.vitorx86.dev)
│   ├── personal-blog/
│   │   ├── compose.yml                     # Ghost (CI-built image from GHCR, digest in GHOST_IMAGE) + local MySQL 8.0; joins the edge network
│   │   └── .env.example, stack.json        # VM .env template & deploy/backup metadata
│   ├── taiga/
│   │   ├── Dockerfile                      # taiga-front + taiga-back (pinned 6.10.3 / 6.10.2) + nginx container
│   │   ├── nginx.conf                      # Nginx gateway routing /, /api, /admin, /static, /media on :8080
│   │   ├── docker-entrypoint.sh            # Idempotent DB migrations, template load & superuser seed
│   │   ├── deploy-cloudrun.sh, cloudrun.env # CI runner: build -> Artifact Registry -> migrations -> Cloud Run (Neon DB; GCS media)
│   │   ├── .env.example, stack.json        # VM .env template & deploy/backup metadata
│   │   └── compose.local.yml               # Local dev compose stack (127.0.0.1:8080)
│   └── scripts/
│       ├── bootstrap_vm.py                 # Idempotent host setup over SSH (Docker, deploy user, swap, sshd, firewall, backup timers)
│       ├── deploy_stack.py                 # rsync + remote .env preflight + compose pull/up --wait (never builds) + HTTPS check (CI & local)
│       ├── backup_stack.py                 # Runs on the VM: DB dump + volumes -> restic in gs://vitorx86-backups
│       ├── tf_apply_retry.sh               # Retries plan+apply on OCI 'Out of host capacity' (refuses destructive plans)
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
- Read credentials exclusively from environment variables (e.g., `GITHUB_TOKEN`, `METRICS_TOKEN`, `DEPLOY_HOST`, `APP_REF`, `BLOG_URL`) or external secret stores, with graceful fallbacks when unauthenticated execution is possible.

### 4. Terraform & VM Stacks
- **Never add a CI workflow that runs `terraform plan/apply`** or stores cloud keys in GitHub (CI reaches GCP only through Workload Identity Federation as `github-deployer`, limited to this repo on `main` in `taiga-prod`); VM roots are applied by hand (`documentation/vm-provisioning.md`), CI only runs `fmt`/`validate`. Keep `prevent_destroy`, `deletion_protection` and the image `ignore_changes` guards.
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
python3 cloud/scripts/configure_ai_spend_cap.py <project_id> --amount 1200 --services all --dry-run

# Spend caps and VM stacks (Terraform is applied from a workstation, never in CI: documentation/vm-provisioning.md)
python3 cloud/scripts/configure_ai_spend_cap.py <project_id> --amount 1200 --services all --dry-run
python3 cloud/scripts/bootstrap_vm.py --host ubuntu@<ip> --provider oracle --deploy-pubkey-file ~/.ssh/blog_deploy.pub --backup-stack personal-blog --dry-run
python3 cloud/scripts/bootstrap_vm.py --host ubuntu@<ip> --provider gce --deploy-pubkey-file ~/.ssh/taiga_deploy.pub --swap-gb 3 --backup-stack taiga --check
python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@<ip> --dry-run
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<ip> --dry-run   # VM side only (.env for backups); Cloud Run deploys run in CI
TAIGA_DB_HOST=x TAIGA_DB_USER=x TAIGA_DB_PASSWORD=x TAIGA_ADMIN_PASSWORD=x cloud/taiga/deploy-cloudrun.sh --dry-run
python3 cloud/scripts/backup_stack.py --stack-dir cloud/taiga --dry-run
cloud/scripts/tf_apply_retry.sh --env oci-blog --dry-run
docker compose -f cloud/personal-blog/compose.yml --env-file cloud/personal-blog/.env.example config -q
terraform -chdir=cloud/infra/envs/gcp-taiga init -backend=false && terraform -chdir=cloud/infra/envs/gcp-taiga validate


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
