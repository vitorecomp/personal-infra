# AGENTS.md

Instructions and context for AI coding agents working in `personal-infra`.

## Project Overview

`personal-infra` is the central automation repository responsible for provisioning, configuring, and maintaining all personal infrastructure for `vitorecomp`.

The repository is organized into four top-level domains:

1. **`cloud/`** — Shared GCP Terraform infrastructure (Global HTTPS Load Balancer, Cloud CDN, SSL certificates, GCS static buckets, Cloud Run + Cloud SQL for MySQL 8.0 + Serverless NEG + Artifact Registry), reverse-proxy configs, and Cloud Build deployment automation for `nobuffer-site`, `personal-portifolio`, and `personal-blog`.
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
│   ├── pipeline-setup.md                   # GitHub Actions, Cloud Build & secrets/variables guide
│   └── workspace-setup.md                  # Local ~/workspace inventory & sync documentation
├── .github/workflows/
│   ├── ci.yml                              # Python syntax/dry-run checks & Terraform fmt/validate
│   ├── terraform-cloud.yml                 # Terraform plan/apply for cloud/infra/envs/prod
│   ├── build-website.yml                   # Fetches nobuffer-site and submits Cloud Build
│   ├── build-portfolio.yml                 # Fetches personal-portifolio and submits Cloud Build
│   ├── build-blog.yml                      # Fetches personal-blog and submits Cloud Build -> Cloud Run
│   ├── deploy-nginx-sites.yml              # Deploys reverse-proxy vhosts to server via SSH
│   └── update-repo-stats.yml               # Scheduled/manual sync of repo_stats.csv
├── cloud/                                  # Cloud infrastructure and deployment automation
│   ├── infra/                              # Shared Terraform modules (load-balancer) and envs (prod)
│   ├── nobuffer-site/
│   │   ├── cloudbuild.yaml                 # Cloud Build pipeline for nobuffer-site
│   │   ├── maintenance/                    # Containerized static maintenance page
│   │   └── reverse-proxy/                  # Nginx vhost configs (*.vitorx86.dev)
│   ├── personal-portifolio/
│   │   └── cloudbuild.yaml                 # Cloud Build static-export pipeline for personal-portifolio
│   ├── personal-blog/
│   │   └── cloudbuild.yaml                 # Cloud Build container & Cloud Run pipeline for personal-blog
│   └── scripts/
│       ├── download_nobuffer_site.py       # Clones/updates nobuffer-site and optionally deploys
│       ├── download_personal_portifolio.py # Clones/updates personal-portifolio and optionally deploys
│       ├── download_personal_blog.py       # Clones/updates personal-blog and optionally deploys
│       └── seed_ghost_admin.py             # Idempotently seeds Ghost Admin Owner in the deploy pipeline
├── home-server/                            # (Planned) Home server setup and maintenance
├── linux/                                  # (Planned) Linux workstation/system configuration
└── workspace/                              # Local repository management
    ├── documentation/
    │   └── repo_stats.csv                  # Source-of-truth repo inventory & folder mapping
    └── scripts/
        ├── update_repo_stats.py            # Syncs GitHub repo metadata into repo_stats.csv
        └── sync_workspace_repos.py         # Moves/clones repos into ~/workspace/<folder>/<name>
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

### 4. Code Style & Dependencies
- **Python**: Target Python 3.10+ using standard library modules (`pathlib`, `argparse`, `csv`, `json`, `subprocess`, `urllib.request`, `concurrent.futures`) whenever possible to keep bootstrap scripts zero-dependency. Use type annotations on all function signatures.
- **Paths**: Resolve paths relative to script locations (`Path(__file__).resolve()`) rather than relying on the caller's working directory, and allow CLI overrides via `argparse`.

### 5. Documentation Hygiene
- When a new domain folder (`cloud/`, `home-server/`, `linux/`, `workspace/`) is populated or updated, update both `README.md` and `AGENTS.md` with its architecture, entrypoints, and verification commands.

---

## Common Commands

```bash
# Preview downloading/updating workloads and Cloud Build submission (safe, read-only)
python3 cloud/scripts/download_nobuffer_site.py --deploy --bucket <nobuffer_bucket> --dry-run
python3 cloud/scripts/download_personal_portifolio.py --deploy --bucket <portfolio_bucket> --dry-run
python3 cloud/scripts/download_personal_blog.py --deploy --dry-run

# Download or update repositories into cloud/<project>/repo
python3 cloud/scripts/download_nobuffer_site.py
python3 cloud/scripts/download_personal_portifolio.py
python3 cloud/scripts/download_personal_blog.py

# Refresh GitHub repository metadata in repo_stats.csv
python3 workspace/scripts/update_repo_stats.py

# Preview ~/workspace organization and cloning (safe, read-only)
python3 workspace/scripts/sync_workspace_repos.py --dry-run

# Apply ~/workspace organization and clone missing assigned repositories
python3 workspace/scripts/sync_workspace_repos.py --jobs 4
```
