# personal-infra

Central repository for automatically provisioning, configuring, and maintaining all personal infrastructure across cloud environments, home server, Linux machines, and local development workspaces.

## Repository Structure

```text
personal-infra/
├── .github/workflows/        # CI/CD workflows (website/blog builds, Terraform, Nginx deploy)
├── documentation/            # Project, architecture, cloud setup, and pipeline documentation
├── cloud/                    # Cloud infrastructure provisioning and workload deployments
│   ├── infra/                # Shared Terraform (GCP LB, Cloud CDN, Cloud Run, SSL cert, GCS)
│   ├── nobuffer-site/        # Cloud Build, Nginx reverse-proxy & maintenance page for nobuffer-site
│   ├── personal-portifolio/  # Cloud Build static-export pipeline for personal-portifolio
│   ├── personal-blog/        # Cloud Build container & Cloud Run deploy pipeline for personal-blog
│   └── scripts/              # Automation scripts to fetch and deploy cloud workloads
├── home-server/              # Home server / self-hosted services and maintenance (TBD)
├── linux/                    # Linux OS bootstrap, packages, and system configuration (TBD)
└── workspace/                # Local ~/workspace repository inventory and synchronization
```

| Directory | Responsibility | Status |
| :--- | :--- | :--- |
| **[`documentation/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/documentation)** | Detailed guides for [Cloud Architecture](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/documentation/cloud-architecture.md), [Cloud Setup](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/documentation/cloud-setup.md), [Pipeline Setup](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/documentation/pipeline-setup.md), and [Workspace Management](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/documentation/workspace-setup.md). | Active |
| **`cloud/`** | Provisioning and maintaining cloud resources, networking, and hosted workloads (`nobuffer-site`, `personal-portifolio`, `personal-blog`). | Active |
| **`home-server/`** | Self-hosted services, container stacks, backups, and home lab automation. | _Planned (to be defined)_ |
| **`linux/`** | Workstation/system setup, packages, dotfiles, and OS-level maintenance scripts. | _Planned (to be defined)_ |
| **`workspace/`** | Automated discovery, organization, and cloning of GitHub repositories into `~/workspace`. | Active |

---

## Modules

### 1. `cloud/`
Manages cloud infrastructure and deployments for hosted sites and services.

- **Shared Terraform Infrastructure ([`cloud/infra/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/infra))**:
  - [`modules/load-balancer`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/infra/modules/load-balancer): Provisions the shared Global External HTTPS Load Balancer, static IP, Managed SSL Certificate, HTTP-to-HTTPS redirect, Cloud CDN + GCS static hosting buckets for `nobuffer-site` and `personal-portifolio`, and Cloud Run v2 + Cloud SQL for MySQL 8.0 + Serverless NEG + Artifact Registry for `personal-blog`.
  - [`envs/prod`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/infra/envs/prod): Production environment configuration.
- **`nobuffer-site` Deployment ([`cloud/nobuffer-site/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/nobuffer-site))**:
  - [`cloudbuild.yaml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/nobuffer-site/cloudbuild.yaml): Compiles the `nobuffer-site` static website (`npm ci && npm run build`) and syncs `build/website` to `gs://${_BUCKET_NAME}`.
  - [`reverse-proxy/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/nobuffer-site/reverse-proxy): Nginx vhost configurations (`demo.vitorx86.dev`, `homeapi.vitorx86.dev`, `maintance.vitorx86.dev`) deployed via [`.github/workflows/deploy-nginx-sites.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/deploy-nginx-sites.yml).
  - [`maintenance/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/nobuffer-site/maintenance): Containerized static maintenance page.
  - [`download_nobuffer_site.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/scripts/download_nobuffer_site.py): Clones/updates `vitorecomp/nobuffer-site` into `cloud/nobuffer-site/repo` (gitignored) and optionally submits the Cloud Build deployment.
- **`personal-portifolio` Deployment ([`cloud/personal-portifolio/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/personal-portifolio))**:
  - [`cloudbuild.yaml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/personal-portifolio/cloudbuild.yaml): Runs the Next.js/Nextra static export (`pnpm run build:export` -> `out/`) and syncs `out/` to `gs://${_BUCKET_NAME}`.
  - [`download_personal_portifolio.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/scripts/download_personal_portifolio.py): Clones/updates `vitorecomp/personal-portifolio` into `cloud/personal-portifolio/repo` (gitignored) and optionally submits the Cloud Build deployment.
- **`personal-blog` Deployment ([`cloud/personal-blog/`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/personal-blog))**:
  - [`cloudbuild.yaml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/personal-blog/cloudbuild.yaml): Validates the custom `vitorx86-garage` Ghost theme and builds/pushes the Ghost 5 container image to Artifact Registry.
  - [`download_personal_blog.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/scripts/download_personal_blog.py): Clones/updates `vitorecomp/personal-blog` into `cloud/personal-blog/repo` (gitignored) and optionally submits the Cloud Build + Cloud Run deployment.
  - [`seed_ghost_admin.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/scripts/seed_ghost_admin.py): Idempotently seeds the initial Ghost Admin Owner account via the Ghost Admin Setup API during the deployment pipeline.

```bash
# Preview downloading/updating and Cloud Build submission (safe, read-only)
python3 cloud/scripts/download_nobuffer_site.py --deploy --bucket <nobuffer_bucket> --dry-run
python3 cloud/scripts/download_personal_portifolio.py --deploy --bucket <portfolio_bucket> --dry-run
python3 cloud/scripts/download_personal_blog.py --deploy --dry-run

# Download/update and deploy workloads via Cloud Build
python3 cloud/scripts/download_nobuffer_site.py --deploy --bucket <nobuffer_bucket>
python3 cloud/scripts/download_personal_portifolio.py --deploy --bucket <portfolio_bucket>
python3 cloud/scripts/download_personal_blog.py --deploy
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

---

## GitHub Actions Workflows

| Workflow | File | Trigger | Description |
| :--- | :--- | :--- | :--- |
| **CI Validation** | [`.github/workflows/ci.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/ci.yml) | Push, PR, manual | Validates Python script syntax, runs `--dry-run` checks across `workspace/` and `cloud/` scripts, and runs `terraform fmt -check` & `terraform validate`. |
| **Terraform Cloud Infrastructure** | [`.github/workflows/terraform-cloud.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/terraform-cloud.yml) | Push/PR on `cloud/infra/**`, manual | Runs `terraform plan` on PRs and applies infrastructure changes to `cloud/infra/envs/prod` on `main`/`master` pushes (or manual `apply=true`). |
| **Build the Main Website** | [`.github/workflows/build-website.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/build-website.yml) | Push, `repository_dispatch` (`deploy-nobuffer-site`), manual | Clones `nobuffer-site` via [`download_nobuffer_site.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/scripts/download_nobuffer_site.py) and submits [`cloud/nobuffer-site/cloudbuild.yaml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/nobuffer-site/cloudbuild.yaml) to Cloud Build. |
| **Build the Personal Portfolio** | [`.github/workflows/build-portfolio.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/build-portfolio.yml) | Push, `repository_dispatch` (`deploy-personal-portifolio`), manual | Clones `personal-portifolio` via [`download_personal_portifolio.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/scripts/download_personal_portifolio.py) and submits [`cloud/personal-portifolio/cloudbuild.yaml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/personal-portifolio/cloudbuild.yaml) to Cloud Build. |
| **Build and Deploy the Personal Blog** | [`.github/workflows/build-blog.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/build-blog.yml) | Push, `repository_dispatch` (`deploy-personal-blog`), manual | Clones `personal-blog` via [`download_personal_blog.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/scripts/download_personal_blog.py) and submits [`cloud/personal-blog/cloudbuild.yaml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/cloud/personal-blog/cloudbuild.yaml) to Cloud Build & Cloud Run. |
| **Deploy the Nginx** | [`.github/workflows/deploy-nginx-sites.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/deploy-nginx-sites.yml) | Push on `cloud/nobuffer-site/reverse-proxy/**`, manual | Copies Nginx reverse-proxy configs over SSH, validates with `nginx -t`, reloads Nginx, and issues Certbot certificates. |
| **Update Workspace Repo Stats** | [`.github/workflows/update-repo-stats.yml`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/.github/workflows/update-repo-stats.yml) | Weekly schedule (Mondays 06:00 UTC), manual | Runs [`update_repo_stats.py`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/scripts/update_repo_stats.py) and commits updated metadata to [`repo_stats.csv`](file:///usr/local/google/home/vieiravitor/workspace/personal/personal-infra/workspace/documentation/repo_stats.csv). |

### Required GitHub Secrets & Variables

- **Secrets (`personal-infra`)**:
  - `GCP_SA_KEY`: GCP service account JSON key for Cloud Build, Cloud Run, Cloud SQL, Artifact Registry, and Terraform.
  - `BLOG_ADMIN_PASSWORD`: Initial Ghost Admin Owner password seeded idempotently during the blog deployment pipeline (`build-blog.yml`).
  - `BLOG_DB_PASSWORD` _(optional)_: Cloud SQL MySQL password for the Ghost user (auto-generated by Terraform if omitted).
  - `HOST`, `USERNAME`, `KEY`: SSH credentials for the Nginx reverse-proxy deployment.
  - `METRICS_TOKEN` _(optional)_: GitHub token with repo read access for `update_repo_stats.py`.
- **Variables (`personal-infra`)**:
  - `GCP_PROJECT_ID`, `GCP_REGION`: Target GCP project and region for Terraform, Cloud SQL, and Cloud Run.
  - `GCS_BUCKET_NAME`: GCS bucket name for `nobuffer-site`.
  - `GCS_PORTFOLIO_BUCKET_NAME`: GCS bucket name for `personal-portifolio`.
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
