# personal-infra

Central repository for automatically provisioning, configuring, and maintaining all personal infrastructure across cloud environments, home server, Linux machines, and local development workspaces.

## Repository Structure

```text
personal-infra/
├── .agents/skills/           # Agent skills (e.g., taiga REST API skill & CLI)
├── .github/workflows/        # CI validation, deploys (images built on runners; Taiga via WIF), repo stats
├── documentation/            # Architecture, provisioning, pipeline, backup and workspace docs
├── cloud/                    # Cloud infrastructure and workload deployments
│   ├── infra/                # Terraform, applied by hand: gcp-taiga (VM + Taiga Cloud Run), oci-blog (spare OCI VM)
│   ├── edge/                 # Shared Caddy on the VM: TLS for blog. and taiga. (Taiga proxied to Cloud Run)
│   ├── nobuffer-site/        # Containerized maintenance page (the site itself is on Vercel)
│   ├── personal-blog/        # Ghost + local MySQL compose stack for the VM
│   ├── taiga/                # Taiga image + Cloud Run deploy script (built/deployed from GitHub Actions)
│   └── scripts/              # bootstrap / deploy / backup / OCI retry scripts, Ghost & Taiga seeders
├── development/              # Cloud & on-prem GPU development machine infrastructure, runner & Podman stack
│   ├── gpu-dev-machine/      # Podman + podman-compose stack (vLLM DeepSeek-V4.1-Flash, LiteLLM, DeepSeek Harness, tunnels, log-shipper)
│   ├── infra/                # Provider-specific GPU machine configs (gcp, azure, on-prem)
│   └── scripts/              # deploy.sh (Regional MIG/machine provisioning), setup.sh (GitHub env sync/runner) & deploy_gpu_stack.sh
├── home-server/              # Home server / self-hosted services and maintenance (TBD)
├── linux/                    # Linux OS bootstrap, packages, and system configuration (TBD)
└── workspace/                # Local ~/workspace repository inventory and synchronization
```

| Directory | Responsibility | Status |
| :--- | :--- | :--- |
| **[`documentation/`](./documentation)** | Guides: [Cloud Architecture](./documentation/cloud-architecture.md), [VM Provisioning](./documentation/vm-provisioning.md), [Pipeline Setup](./documentation/pipeline-setup.md), [Backup & Restore](./documentation/backup-restore.md), [Workspace Management](./documentation/workspace-setup.md). | Active |
| **`cloud/`** | Provisioning and maintaining cloud resources, networking, and hosted workloads (`nobuffer-site`, `personal-portifolio`, `personal-blog`, `taiga`). | Active |
| **[`development/`](./development)** | Provisioning GPU development machines (`scripts/deploy.sh`) and configuring self-hosted GitHub runners (`scripts/setup.sh`) across `gcp`, `azure`, and `on-prem`. | Active (GCP Terraform; Azure/on-prem planned) |
| **`home-server/`** | Self-hosted services, container stacks, backups, and home lab automation. | _Planned (to be defined)_ |
| **`linux/`** | Workstation/system setup, packages, dotfiles, and OS-level maintenance scripts. | _Planned (to be defined)_ |
| **`workspace/`** | Automated discovery, organization, and cloning of GitHub repositories into `~/workspace`. | Active |

---

## Modules

### 1. `cloud/`

| Site | Runs on | Defined in |
| :--- | :--- | :--- |
| `$ROOT_DOMAIN`, `www` | Vercel (Git integration on `vitorecomp/nobuffer-site`) | app repo (`vercel.json`) |
| `me.`, `cases.` | Vercel (Git integration on `vitorecomp/personal-portifolio`) | app repo (`vercel.json`) |
| `blog.` (`$BLOG_DOMAIN`) | GCE e2-micro VM `personal-host` (free tier): edge Caddy → Ghost 5.130 → local MySQL 8.0 | [`cloud/edge`](./cloud/edge), [`cloud/personal-blog`](./cloud/personal-blog) |
| `taiga.` (`$TAIGA_DOMAIN`) | Cloud Run `taiga` (free tier) via the edge Caddy; database on Neon (Postgres 15); uploads in GCS | [`cloud/taiga`](./cloud/taiga) |

DNS is on Cloudflare (DNS-only records, managed by hand). All personal domains, emails, Cloud Run URLs, and GCP project/bucket names live in the gitignored root [`.env`](./.env.example) and are synced to GitHub Secrets via [`sync_github_secrets.py`](./cloud/scripts/sync_github_secrets.py). Details: [cloud-architecture.md](./documentation/cloud-architecture.md).

- **Terraform (applied by hand, never in CI)**: [`cloud/infra/envs/gcp-taiga`](./cloud/infra/envs/gcp-taiga) (VM, Taiga Cloud Run + Artifact Registry + Secret Manager + media bucket, backup bucket) and [`cloud/infra/envs/oci-blog`](./cloud/infra/envs/oci-blog) (spare OCI A1 VM, still being acquired by a retry loop). Runbook: [vm-provisioning.md](./documentation/vm-provisioning.md).
- **Stacks**: `cloud/<stack>/` with `stack.json` + `.env.example` (+ `compose.yml` when it runs on the VM). Nothing is built on the VM: the blog image is built in CI and pulled from GHCR, Taiga is built and deployed to Cloud Run from CI. Secrets live only in `/opt/stacks/<stack>/.env` on the VM, Secret Manager (Taiga runtime) and GitHub Secrets.
- **Scripts** (stdlib Python / bash, all with `--dry-run`):
  [`sync_github_secrets.py`](./cloud/scripts/sync_github_secrets.py) (syncs root `.env` to GitHub Secrets),
  [`bootstrap_vm.py`](./cloud/scripts/bootstrap_vm.py) (host setup, `--check` for drift, `--tunnel-pubkey-file` for the GPU machine's reverse-tunnel user),
  [`deploy_stack.py`](./cloud/scripts/deploy_stack.py) (rsync + `.env` preflight + `compose pull`/`up --wait` + HTTPS check; used by CI and locally),
  [`backup_stack.py`](./cloud/scripts/backup_stack.py) (DB dumps incl. remote Neon, volumes, GCS buckets → restic in `gs://$BACKUP_BUCKET`),
  [`tf_apply_retry.sh`](./cloud/scripts/tf_apply_retry.sh) (OCI capacity retry loop),
  [`configure_ai_spend_cap.py`](./cloud/scripts/configure_ai_spend_cap.py).

```bash
python3 cloud/scripts/bootstrap_vm.py --host ubuntu@<ip> --provider gce --deploy-pubkey-file ~/.ssh/blog_deploy.pub --check
python3 cloud/scripts/deploy_stack.py --stack personal-blog --host deploy@<ip> --identity-file ~/.ssh/blog_deploy --dry-run
python3 cloud/scripts/deploy_stack.py --stack taiga --host deploy@<ip> --identity-file ~/.ssh/taiga_deploy      # VM side only (backup .env); Cloud Run deploys: cloud/taiga/deploy-cloudrun.sh in deploy-taiga.yml
ssh deploy@<ip> 'python3 /opt/stacks/.ops/backup_stack.py --stack taiga --restore-test'
python3 cloud/scripts/configure_ai_spend_cap.py <project_id> --amount 1200 --services all --dry-run
```

### 2. `development/`
Provisions and configures GPU development workstations across cloud and on-prem targets:

- **Infrastructure ([`development/infra/`](./development/infra))**:
  - [`gcp/`](./development/infra/gcp): GCP Terraform provisioning a **zero-SSH Stateless Multi-Zone Regional Managed Instance Group** (`dev-gpu-mig`, `target_size = 1`, `distribution_policy_target_shape = "ANY"`, `allow_changing_zone = "YES"`, `replacement_method = "SUBSTITUTE"`, autohealing on the `gpu-health` host probe, `g4-standard-192` by default) spanning all GPU-capable zones in the target region (overridable via `--zones` or `--zone`), configurable as **Spot** (`use_spot = true`, default) or **Standard** on-demand (`--no-spot`), on a custom VPC or existing `default` VPC (`--use-default-vpc`), with an ephemeral `3000 GB` Hyperdisk (`auto_delete = true`), a **same-region GCS cache bucket** (`<project>-<prefix>-cache-<region>`, `$0` regional transfer), and a **GCP Secret Manager** bootstrap secret (`dev-gpu-runner-bootstrap`). On boot, the GPU VM restores runner credentials, stack configs, DeepSeek Harness workspace, reverse-tunnel config, and Hugging Face model weights from GCS (falling back to Secret Manager for registration), runs a 15-minute `gpu-gcs-sync.timer` + shutdown flush (`gpu-gcs-sync --fast`), self-starts `gcp-gpu-runner` over outbound HTTPS 443, and auto-resumes any deployed Podman stack across cross-zone Spot failovers.
  - [`azure/`](./development/infra/azure) & [`on-prem/`](./development/infra/on-prem): Reserved target folders (`.gitkeep`) for Azure and on-premises GPU hosts.
- **GPU Machine Container Stack ([`development/gpu-dev-machine/`](./development/gpu-dev-machine))**: Podman + `podman-compose` stack running `vllm-server` (vLLM's OpenAI server: full unquantized `deepseek-ai/DeepSeek-V4.1-Flash` with CPU offload), `litellm`, and `deepseek-harness` pointed at LiteLLM.
- **Scripts ([`development/scripts/`](./development/scripts))**:
  - [`deploy.sh`](./development/scripts/deploy.sh): Unified Terraform provisioning entrypoint (`--provider=<gcp|azure|on-prem>`, `--spot` / `--no-spot`, `--use-default-vpc`, `--zones=z1,z2`, `--cache-bucket=NAME`, `--cycle-regions`, `--loop=<minutes>`) using logged-in `gcloud` / ADC credentials and active project; cycles by region across all GPU zones, enables `storage.googleapis.com`, and auto-mints a runner registration token via `gh api` into Secret Manager on GCP when `RUNNER_PAT` is omitted.
  - [`setup.sh`](./development/scripts/setup.sh): Reads gitignored `development/.env` ([`.env.example`](./development/.env.example)) and syncs Repository (`GPU_RUNNER`, `GPU_RUNNER_LABELS`) & `gpu` Environment variables/secrets (`GPU_TARGET_MODE=local`, `LITELLM_MASTER_KEY`, etc.) via `gh`. Zero-SSH on GCP (including `--status` inspecting `gh api` runners and Regional MIG instances via `--region`, plus `--remove` via `gh api`); SSH runner setup is used for `azure`, `on-prem`, or explicit `--host=user@ip`.
  - [`deploy_gpu_stack.sh`](./development/scripts/deploy_gpu_stack.sh): Syncs and deploys `development/gpu-dev-machine` via `podman-compose` directly on the GPU runner (`GPU_TARGET_MODE=local` on GCP, or over SSH for remote hosts) and immediately flushes updated configs to GCS via `gpu-gcs-sync --fast`.

```bash
./development/scripts/setup.sh --provider=gcp --dry-run
./development/scripts/deploy.sh --provider=gcp --dry-run
./development/scripts/deploy.sh --provider=gcp --no-spot --use-default-vpc --dry-run
./development/scripts/deploy.sh --provider=gcp --region=europe-west2 --zones=europe-west2-b,europe-west2-c --dry-run
```

### 3. `home-server/`
_Details to be added._ Will hold configurations, service definitions, and maintenance workflows for the home server.

### 4. `linux/`
_Details to be added._ Will hold scripts and configuration files to bootstrap and maintain Linux environments.

### 5. `workspace/`
Manages the local `~/workspace` directory hierarchy based on a tracked inventory of GitHub repositories.

- **Inventory ([`repo_stats.json`](./workspace/documentation/repo_stats.json))**: Tracks repository metadata (`last_updated`, `link`, `ssh_link`, `is_fork`) alongside manual curation fields (`folder`, `is_custom`, `is_template`), sorted alphabetically by repository name to avoid Git merge conflicts.
- **Update Inventory ([`update_repo_stats.py`](./workspace/scripts/update_repo_stats.py))**: Queries the GitHub API for `vitorecomp` repositories, updates metadata in `repo_stats.json` while preserving manual fields (`folder`, `is_custom`, `is_template`), and keeps entries sorted alphabetically by repository name.
  ```bash
  # Optional: export GITHUB_TOKEN or METRICS_TOKEN to include private repos / avoid rate limits
  python3 workspace/scripts/update_repo_stats.py
  ```
- **Sync Workspace ([`sync_workspace_repos.py`](./workspace/scripts/sync_workspace_repos.py))**: Organizes already-cloned repositories into `~/workspace/<folder>/<name>` and clones any missing repositories that have a target `folder` assigned in `repo_stats.json`.
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
- **Backup & Restore Workspace `.env` Files ([`workspace_envs.sh`](./workspace/scripts/workspace_envs.sh))**: Unified wrapper entrypoint (`--backup` default, `--restore` to restore) that runs the underlying Python scripts ([`backup_workspace_envs.py`](./workspace/scripts/backup_workspace_envs.py) & [`restore_workspace_envs.py`](./workspace/scripts/restore_workspace_envs.py)) inside an isolated, gitignored `workspace/.venv` virtual environment (`--venv-dir`, `--rebuild-venv`; read-only on `--dry-run` / `--help`). Discovers `.env` and non-template `.env.*` files across `~/workspace` (including hidden config paths like `.agents/skills/taiga/.env`, while skipping templates and `node_modules`/`.venv`/`.git`), idempotently backs them up to a gitignored mode-`0600` zip (`workspace/backups/workspace-envs.zip`) and/or Bitwarden Secure Notes (`workspace-envs` folder via `bw` + `BW_SESSION`), and safely restores them to `0600` files with `ZipSlip` protection, `--overwrite`, and `--existing-dirs-only`.
  ```bash
  # Preview backup & restore actions (read-only; does not create workspace/.venv)
  ./workspace/scripts/workspace_envs.sh --zip --dry-run
  ./workspace/scripts/workspace_envs.sh --backup --bitwarden --dry-run
  ./workspace/scripts/workspace_envs.sh --restore --zip --dry-run
  ./workspace/scripts/workspace_envs.sh --restore --bitwarden --dry-run

  # Back up to gitignored zip and Bitwarden Vault, then restore safely
  ./workspace/scripts/workspace_envs.sh --zip --bitwarden
  ./workspace/scripts/workspace_envs.sh --restore --zip --existing-dirs-only
  ```
- **Enroll GitHub Repositories on Taiga ([`enroll_taiga_projects.py`](./workspace/scripts/enroll_taiga_projects.py))**: Idempotently enrolls GitHub repositories from `repo_stats.json` as Scrum projects on `$TAIGA_URL` and orders them with the most recently committed repository first.
  ```bash
  python3 workspace/scripts/enroll_taiga_projects.py --dry-run
  python3 workspace/scripts/enroll_taiga_projects.py
  ```
- **Taiga REST API CLI & Agent Skill ([`taiga_cli.py`](./.agents/skills/taiga/scripts/taiga_cli.py) / [`SKILL.md`](./.agents/skills/taiga/SKILL.md))**: Manages projects, Scrum sprints, user stories, tasks, issues, epics, and wiki pages via the Taiga REST API (`/api/v1`). Both Taiga scripts read their settings from the gitignored root [`.env`](./.env.example) (or [`.agents/skills/taiga/.env`](./.agents/skills/taiga/.env.example), mode 0600; falls back to the `taiga-admin-password` secret via `gcloud`).
  ```bash
  cp -n .env.example .env && chmod 600 .env   # once, then fill in TAIGA_URL / GCP_PROJECT_ID
  python3 workspace/scripts/taiga_cli.py projects list
  python3 workspace/scripts/taiga_cli.py stories list personal-infra
  python3 workspace/scripts/taiga_cli.py stories create personal-infra --subject "Add feature" --points 3 --dry-run
  ```

---

## GitHub Actions Workflows

| Workflow | File | Trigger | Description |
| :--- | :--- | :--- | :--- |
| **CI Validation** | [`ci.yml`](./.github/workflows/ci.yml) | Push, PR, manual | Secret scan (files + history), Python syntax and `--dry-run` checks, `terraform fmt -check` / `validate` for every root (no plan/apply), stack validation (`docker compose config`, `caddy validate`, shell syntax). |
| **Deploy the Personal Blog (GCP VM)** | [`deploy-blog.yml`](./.github/workflows/deploy-blog.yml) | Push on `cloud/personal-blog/**`, `cloud/edge/**`, `deploy_stack.py`, `backup_stack.py`, `seed_ghost_admin.py` or the workflow; `repository_dispatch` (`deploy-personal-blog`); manual | Runner builds the Ghost image from `vitorecomp/personal-blog` and pushes it to GHCR; SSH to the VM: edge + blog pull/restart via `deploy_stack.py`. Environment `blog-prod`. |
| **Deploy Taiga (Cloud Run)** | [`deploy-taiga.yml`](./.github/workflows/deploy-taiga.yml) | Push on `cloud/taiga/**`, `cloud/edge/**`, `deploy_stack.py`, `backup_stack.py`, `seed_taiga_admin.py` or the workflow; `repository_dispatch` (`deploy-taiga`); manual | Runner (keyless, Workload Identity Federation): `deploy-cloudrun.sh` (build, migrations against Neon, Secret Manager sync, Cloud Run revision); then SSH to the VM for the edge stack and Taiga's backup `.env`. Environment `taiga-prod`. |
| **Deploy GPU Dev Machine Stack** | [`deploy-gpu-machine.yml`](./.github/workflows/deploy-gpu-machine.yml) | Push on `development/gpu-dev-machine/**`, `deploy_gpu_stack.sh`, or the workflow; manual | Self-hosted runner selected by repo variable `GPU_RUNNER` (`gcp-gpu`, `azure-gpu`, `on-prem-gpu`): syncs and deploys the Podman + `podman-compose` stack (`vllm-server`, `litellm`, `deepseek-harness`, reverse tunnels) via [`deploy_gpu_stack.sh`](./development/scripts/deploy_gpu_stack.sh). Environment `gpu`. |
| **Update Workspace Repo Stats** | [`update-repo-stats.yml`](./.github/workflows/update-repo-stats.yml) | Weekly (Mon 06:00 UTC), manual | Refreshes [`repo_stats.json`](./workspace/documentation/repo_stats.json). |

### GitHub Secrets & Variables

- **Environments `blog-prod` / `taiga-prod` / `gpu`** (deployments from `main` only): `blog-prod` and `taiga-prod` hold secrets `DEPLOY_HOST`, `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`, `BLOG_ADMIN_EMAIL` / `TAIGA_ADMIN_EMAIL`, and variable `DEPLOY_USER`. `taiga-prod` also holds secrets `TAIGA_DB_HOST` / `TAIGA_DB_USER` / `TAIGA_DB_PASSWORD` (Neon), `TAIGA_ADMIN_PASSWORD`, and variables `TAIGA_DB_NAME`, optional `TAIGA_ADMIN_USER` (default `admin`). `gpu` (gated by required reviewer `vitorecomp`) holds secrets `LITELLM_MASTER_KEY`, optional `HF_TOKEN`, `TUNNEL_SSH_PRIVATE_KEY`, optional `GPU_SSH_PRIVATE_KEY` and variables `GPU_TARGET_MODE` (`local` on GCP MIG runner), `ENABLE_REVERSE_TUNNELS`, `TUNNEL_SSH_HOST`, `TUNNEL_SSH_USER`, `TUNNEL_SSH_PORT`, `TUNNEL_KNOWN_HOSTS`, `TUNNEL_BIND_ADDRESS`, `REMOTE_LITELLM_PORT`, `REMOTE_HARNESS_PORT` (model & offload parameters live directly in [`development/gpu-dev-machine/compose.yml`](./development/gpu-dev-machine/compose.yml)).
- **Repository**: secrets `TAIGA_DOMAIN`, `BLOG_DOMAIN`, `ACME_EMAIL`, `TAIGA_UPSTREAM`, `GCP_PROJECT_ID`, `TAIGA_RUN_SA`, `TAIGA_MEDIA_BUCKET`, `BACKUP_BUCKET`, `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA`, `BLOG_TITLE`, `BLOG_THEME_NAME`, `ADMIN_NAME` (all synced from gitignored root `.env` by [`sync_github_secrets.py`](./cloud/scripts/sync_github_secrets.py) so GitHub Actions masks them in public logs), plus `BLOG_ADMIN_PASSWORD` and `METRICS_TOKEN`; variable `GPU_RUNNER` (`gcp-gpu`, `azure-gpu`, `on-prem-gpu`; optional `GPU_RUNNER_LABELS`).
- No cloud keys live in GitHub: Terraform runs from a workstation; the Taiga deploy impersonates `github-deployer` through Workload Identity Federation (this repo, `main`, `taiga-prod` only); the blog image goes to GHCR with the job's `GITHUB_TOKEN`.

---

## Core Principles

- **Idempotent Execution**: Scripts and provisioning workflows can be re-run safely at any time without unintended side effects.
- **Dry-Run Support**: Destructive or state-changing tools provide a `--dry-run` / preview mode before applying changes.
- **No Committed Secrets**: Credentials, tokens, and private keys are supplied strictly via environment variables or secret managers.

## License

Released under the [MIT License](./LICENSE).
