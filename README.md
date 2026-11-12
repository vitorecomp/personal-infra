# personal-infra

Central repository for automatically provisioning, configuring, and maintaining all personal infrastructure across cloud environments, home server, Linux machines, and local development workspaces.

## Repository Structure

```text
personal-infra/
├── .agents/skills/           # Agent skills (e.g., taiga REST API skill & CLI)
├── .github/workflows/        # CI/CD workflows (CI validation, SSH stack deploys, legacy Cloud Build, Nginx deploy)
├── documentation/            # Project, architecture, cloud setup, and pipeline documentation
├── cloud/                    # Cloud infrastructure provisioning and workload deployments
│   ├── infra/                # Terraform (applied by hand): GCP VM (gcp-taiga), spare OCI VM (oci-blog), legacy GCP LB (prod)
│   ├── edge/                 # Shared Caddy on the GCP VM: TLS + routing for taiga. and blog.
│   ├── nobuffer-site/        # Nginx reverse-proxy & maintenance page (the site itself is on Vercel)
│   ├── personal-blog/        # Ghost + local MySQL compose stack for the GCP VM (+ legacy Cloud Build)
│   ├── taiga/                # Taiga image + compose stack for the GCE VM (+ legacy Cloud Build)
│   └── scripts/              # bootstrap/deploy/backup/migration scripts + legacy Cloud Build helpers
├── home-server/              # Home server / self-hosted services and maintenance (TBD)
├── linux/                    # Linux OS bootstrap, packages, and system configuration (TBD)
└── workspace/                # Local ~/workspace repository inventory and synchronization
```

| Directory | Responsibility | Status |
| :--- | :--- | :--- |
| **[`documentation/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/documentation)** | Detailed guides for [Cloud Architecture](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/documentation/cloud-architecture.md), [Cloud Setup](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/documentation/cloud-setup.md), [Pipeline Setup](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/documentation/pipeline-setup.md), and [Workspace Management](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/documentation/workspace-setup.md). | Active |
| **`cloud/`** | Provisioning and maintaining cloud resources, networking, and hosted workloads (`nobuffer-site`, `personal-portifolio`, `personal-blog`, `taiga`). | Active |
| **`home-server/`** | Self-hosted services, container stacks, backups, and home lab automation. | _Planned (to be defined)_ |
| **`linux/`** | Workstation/system setup, packages, dotfiles, and OS-level maintenance scripts. | _Planned (to be defined)_ |
| **`workspace/`** | Automated discovery, organization, and cloning of GitHub repositories into `~/workspace`. | Active |

---

## Modules

### 1. `cloud/`
Manages cloud infrastructure and deployments for hosted sites and services.

> **Migration in progress**: see the [migration runbook](./documentation/migration-runbook.md). Target layout:
> `nobuffer-site` + `personal-portifolio` on **Vercel** (done: Git integration on the app repos, no workflow here), `personal-blog` (Ghost + local MySQL) and `taiga` on one **GCE free-tier e2-micro VM** behind a shared Caddy
> (`cloud/edge`), Taiga's database on **Neon** (managed Postgres 15), all deployed over SSH.
> The legacy GCP stack described further below keeps serving until each cutover.

- **VM Terraform (applied by hand, [runbook](./documentation/vm-provisioning.md))**:
  [`cloud/infra/envs/gcp-taiga`](./cloud/infra/envs/gcp-taiga) ([`modules/gce-vm`](./cloud/infra/modules/gce-vm)) and
  [`cloud/infra/envs/oci-blog`](./cloud/infra/envs/oci-blog) ([`modules/oci-vm`](./cloud/infra/modules/oci-vm), spare OCI VM still being acquired).
  CI only runs `fmt`/`validate`.
- **Compose stacks**: [`cloud/edge`](./cloud/edge) (shared Caddy), [`cloud/personal-blog`](./cloud/personal-blog) and [`cloud/taiga`](./cloud/taiga)
  (`compose.yml`, `.env.example`, `stack.json`). Secrets live in `/opt/stacks/<stack>/.env` on the VM; Taiga's Neon credentials are synced there from the `taiga-prod` GitHub environment.
- **Scripts** (stdlib Python, all with `--dry-run`):
  [`bootstrap_vm.py`](./cloud/scripts/bootstrap_vm.py) (Docker, deploy user, swap, sshd, firewall, backup timers; `--check` for drift),
  [`deploy_stack.py`](./cloud/scripts/deploy_stack.py) (rsync + `docker compose up --wait` + HTTPS check; used by CI and locally),
  [`backup_stack.py`](./cloud/scripts/backup_stack.py) (DB dump + volumes → restic in the `vitorx86-backups` GCS bucket),
  [`migrate_gcp_data.py`](./cloud/scripts/migrate_gcp_data.py) (temporary: Cloud SQL/GCS → VMs).

```bash
python3 cloud/scripts/bootstrap_vm.py --host ubuntu@<ip> --provider oracle --deploy-pubkey-file ~/.ssh/blog_deploy.pub --backup-stack personal-blog --dry-run
python3 cloud/scripts/bootstrap_vm.py --host ubuntu@<ip> --provider oracle --deploy-pubkey-file ~/.ssh/blog_deploy.pub --backup-stack personal-blog --check
python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@<ip> --dry-run
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<ip> --init-env
python3 cloud/scripts/migrate_gcp_data.py all --stack taiga --host deploy@<ip> --confirm-overwrite --dry-run
ssh deploy@<ip> 'python3 /opt/stacks/.ops/backup_stack.py --stack taiga --restore-test'
```

**Legacy GCP stack (until Phase 5 of the runbook):**

- **Shared Terraform Infrastructure ([`cloud/infra/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/infra))**:
  - [`modules/load-balancer`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/infra/modules/load-balancer): Provisions the shared Global External HTTPS Load Balancer, static IP, Managed SSL Certificate, HTTP-to-HTTPS redirect, Cloud CDN + GCS static hosting buckets for `nobuffer-site` and `personal-portifolio`, and Cloud Run v2 + Cloud SQL for MySQL 8.0 + Serverless NEG + Artifact Registry for `personal-blog`.
  - [`envs/prod`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/infra/envs/prod): Production environment configuration.
- **`nobuffer-site` extras ([`cloud/nobuffer-site/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/nobuffer-site))**:
  - [`reverse-proxy/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/nobuffer-site/reverse-proxy): Nginx vhost configurations (`demo.vitorx86.dev`, `homeapi.vitorx86.dev`, `maintance.vitorx86.dev`) deployed via [`.github/workflows/deploy-nginx-sites.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/deploy-nginx-sites.yml).
  - [`maintenance/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/nobuffer-site/maintenance): Containerized static maintenance page.
- **`personal-blog` Deployment ([`cloud/personal-blog/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/personal-blog))**:
  - [`cloudbuild.yaml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/personal-blog/cloudbuild.yaml): Validates the custom `vitorx86-garage` Ghost theme and builds/pushes the Ghost 5 container image to Artifact Registry.
  - [`download_personal_blog.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/scripts/download_personal_blog.py): Clones/updates `vitorecomp/personal-blog` into `cloud/personal-blog/repo` (gitignored) and optionally submits the Cloud Build + Cloud Run deployment.
  - [`seed_ghost_admin.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/scripts/seed_ghost_admin.py): Idempotently seeds the initial Ghost Admin Owner account via the Ghost Admin Setup API during the deployment pipeline.

```bash
# Preview downloading/updating and Cloud Build submission (safe, read-only)
python3 cloud/scripts/download_personal_blog.py --deploy --dry-run
python3 cloud/scripts/deploy_taiga.py --deploy --dry-run
python3 cloud/scripts/configure_ai_spend_cap.py <project_id> --amount 1200 --services all --dry-run

# Download/update and deploy workloads via Cloud Build
python3 cloud/scripts/download_personal_blog.py --deploy
python3 cloud/scripts/deploy_taiga.py --deploy
python3 cloud/scripts/configure_ai_spend_cap.py <project_id> --amount 1200 --services all
```

### 2. `home-server/`
_Details to be added._ Will hold configurations, service definitions, and maintenance workflows for the home server.

### 3. `linux/`
_Details to be added._ Will hold scripts and configuration files to bootstrap and maintain Linux environments.

### 4. `workspace/`
Manages the local `~/workspace` directory hierarchy based on a tracked inventory of GitHub repositories.

- **Inventory ([`repo_stats.csv`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/documentation/repo_stats.csv))**: Tracks repository metadata (`name`, `link`, `ssh link`, `last updated`, `is a fork`) alongside manual curation fields (`folder`, `is-custom`, `is-template`).
- **Update Inventory ([`update_repo_stats.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/scripts/update_repo_stats.py))**: Queries the GitHub API for `vitorecomp` repositories, updates metadata in `repo_stats.csv` while preserving manual columns (`folder`, `is-custom`, `is-template`), and orders all rows by `last updated` descending.
  ```bash
  # Optional: export GITHUB_TOKEN or METRICS_TOKEN to include private repos / avoid rate limits
  python3 workspace/scripts/update_repo_stats.py
  ```
- **Sync Workspace ([`sync_workspace_repos.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/scripts/sync_workspace_repos.py))**: Organizes already-cloned repositories into `~/workspace/<folder>/<name>` and clones any missing repositories that have a target `folder` assigned in `repo_stats.csv`.
  ```bash
  # Preview moves and clones without modifying the filesystem
  python3 workspace/scripts/sync_workspace_repos.py --dry-run

  # Execute workspace synchronization
  python3 workspace/scripts/sync_workspace_repos.py --jobs 4
  ```
- **Validate Repositories Pushed ([`validate_repos_pushed.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/scripts/validate_repos_pushed.py))**: Scans `~/workspace` (or a specific subfolder/category) and checks that every Git repository has a configured remote, a clean working tree, and all local commits pushed.
  ```bash
  # Validate all repositories in ~/workspace
  python3 workspace/scripts/validate_repos_pushed.py

  # Validate a specific category folder (e.g., ~/workspace/personal)
  python3 workspace/scripts/validate_repos_pushed.py personal
  ```
- **Scan Repository Secrets & Pre-Commit Guard ([`scan_repo_secrets.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/scripts/scan_repo_secrets.py))**: Scans tracked files, staged index changes, and full Git commit history for leaked keys, cloud credentials, API tokens, and unignored secret files, and idempotently installs a local Git `pre-commit` hook.
  ```bash
  # Audit tracked files and full Git commit history
  python3 workspace/scripts/scan_repo_secrets.py --history

  # Preview and install the local Git pre-commit secret-scanning hook
  python3 workspace/scripts/scan_repo_secrets.py --install-hook --dry-run
  python3 workspace/scripts/scan_repo_secrets.py --install-hook
  ```
- **Enroll GitHub Repositories on Taiga ([`enroll_taiga_projects.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/scripts/enroll_taiga_projects.py))**: Idempotently enrolls GitHub repositories from `repo_stats.csv` as Scrum projects on `https://taiga.vitorx86.dev` and orders them with the most recently committed repository first.
  ```bash
  python3 workspace/scripts/enroll_taiga_projects.py --dry-run
  python3 workspace/scripts/enroll_taiga_projects.py
  ```
- **Taiga REST API CLI & Agent Skill ([`taiga_cli.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.agents/skills/taiga/scripts/taiga_cli.py) / [`SKILL.md`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.agents/skills/taiga/SKILL.md))**: Manages projects, Scrum sprints, user stories, tasks, issues, epics, and wiki pages via the Taiga REST API (`/api/v1`).
  ```bash
  python3 workspace/scripts/taiga_cli.py projects list
  python3 workspace/scripts/taiga_cli.py stories list personal-infra
  python3 workspace/scripts/taiga_cli.py stories create personal-infra --subject "Add feature" --points 3 --dry-run
  ```

---

## GitHub Actions Workflows

| Workflow | File | Trigger | Description |
| :--- | :--- | :--- | :--- |
| **CI Validation** | [`.github/workflows/ci.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/ci.yml) | Push, PR, manual | Scans tracked files and Git history for secrets, validates Python script syntax, runs `--dry-run` checks across `workspace/` and `cloud/` scripts, runs `terraform fmt -check` & `terraform validate` for every Terraform root (no plan/apply), and validates the compose stacks (`docker compose config`, `caddy validate`). |
| **Deploy the Personal Blog (GCP VM)** | [`.github/workflows/deploy-blog.yml`](./.github/workflows/deploy-blog.yml) | Push on `cloud/personal-blog/**`, `repository_dispatch` (`deploy-personal-blog`), manual | SSH deploy (edge + blog) via `deploy_stack.py` to the GCP VM. Gated by `BLOG_DEPLOY_ENABLED`; environment `blog-prod`. |
| **Deploy Taiga (GCE VM)** | [`.github/workflows/deploy-taiga.yml`](./.github/workflows/deploy-taiga.yml) | Push on `cloud/taiga/**`, `repository_dispatch` (`deploy-taiga`), manual | SSH deploy via `deploy_stack.py` to the GCE VM. Gated by `TAIGA_DEPLOY_ENABLED`; environment `taiga-prod`. |
| **Build and Deploy the Personal Blog** _(legacy)_ | [`.github/workflows/build-blog.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/build-blog.yml) | `repository_dispatch` (`deploy-personal-blog`), manual | Clones `personal-blog` via [`download_personal_blog.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/scripts/download_personal_blog.py) and submits [`cloud/personal-blog/cloudbuild.yaml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/personal-blog/cloudbuild.yaml) to Cloud Build & Cloud Run. |
| **Deploy the Nginx** | [`.github/workflows/deploy-nginx-sites.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/deploy-nginx-sites.yml) | Push on `cloud/nobuffer-site/reverse-proxy/**`, manual | Copies Nginx reverse-proxy configs over SSH, validates with `nginx -t`, reloads Nginx, and issues Certbot certificates. |
| **Update Workspace Repo Stats** | [`.github/workflows/update-repo-stats.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/update-repo-stats.yml) | Weekly schedule (Mondays 06:00 UTC), manual | Runs [`update_repo_stats.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/scripts/update_repo_stats.py) and commits updated metadata to [`repo_stats.csv`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/documentation/repo_stats.csv). |

### Required GitHub Secrets & Variables

- **VM deploys (environments `blog-prod` / `taiga-prod`)**: secrets `DEPLOY_HOST`, `DEPLOY_SSH_KEY`; variables `DEPLOY_KNOWN_HOSTS`, `DEPLOY_USER`; repository variables `BLOG_DEPLOY_ENABLED` / `TAIGA_DEPLOY_ENABLED`. See [pipeline-setup.md §5](./documentation/pipeline-setup.md#5-vm-deploy-workflows-ssh). The GCP entries below belong to the legacy stack and are deleted in Phase 5.
- **Secrets (`personal-infra`)**:
  - `GCP_SA_KEY`: GCP service account JSON key for Cloud Build, Cloud Run, Cloud SQL, Artifact Registry, and Terraform.
  - `BLOG_ADMIN_PASSWORD`: Initial Ghost Admin Owner password seeded idempotently during the blog deployment pipeline (`build-blog.yml`).
  - `BLOG_DB_PASSWORD` _(optional)_: Cloud SQL MySQL password for the Ghost user (auto-generated by Terraform if omitted).
  - `HOST`, `USERNAME`, `KEY`: SSH credentials for the Nginx reverse-proxy deployment.
  - `METRICS_TOKEN` _(optional)_: GitHub token with repo read access for `update_repo_stats.py`.
- **Variables (`personal-infra`)**:
  - `GCP_PROJECT_ID`, `GCP_REGION`: Target GCP project and region for Terraform, Cloud SQL, and Cloud Run.
  - `GCS_BLOG_CONTENT_BUCKET_NAME` _(optional)_: GCS bucket name for persistent Ghost media/images on Cloud Run.
  - `BLOG_DB_INSTANCE_NAME`, `BLOG_DB_TIER`, `BLOG_DB_NAME`, `BLOG_DB_USER` _(optional)_: Cloud SQL MySQL 8.0 settings for `personal-blog`.
  - `GAR_BLOG_REPO`, `CLOUD_RUN_BLOG_SERVICE`, `BLOG_URL`, `BLOG_ADMIN_EMAIL` _(optional)_: Artifact Registry repo, Cloud Run service name, public URL, and initial Ghost Admin Owner email for `personal-blog`.
  - `NOBUFFER_DOMAINS`, `PORTFOLIO_DOMAINS`, `BLOG_DOMAINS` _(optional JSON lists)_: Domains routed by the shared load balancer.
- **Secrets (`nobuffer-site`, `personal-portifolio` & `personal-blog`)**:
  - `PERSONAL_INFRA_TOKEN` (or `METRICS_TOKEN`): Fine-grained PAT or token with `contents: write` / `actions: write` on `vitorecomp/personal-infra` to trigger `repository_dispatch`.

---

## Core Principles

- **Idempotent Execution**: Scripts and provisioning workflows can be re-run safely at any time without unintended side effects.
- **Dry-Run Support**: Destructive or state-changing tools provide a `--dry-run` / preview mode before applying changes.
- **No Committed Secrets**: Credentials, tokens, and private keys are supplied strictly via environment variables or secret managers.

## License

Released under the [MIT License](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/LICENSE).
