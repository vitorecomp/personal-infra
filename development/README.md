# `development/` — Cloud & On-Prem GPU Development Workflow

End-to-end automation and runbook for syncing GitHub Actions variables/secrets and managing runners ([`scripts/setup.sh`](./scripts/setup.sh)), provisioning GPU development machines ([`scripts/deploy.sh`](./scripts/deploy.sh)), and deploying the GPU Podman inference & harness stack ([`scripts/deploy_gpu_stack.sh`](./scripts/deploy_gpu_stack.sh)) across **GCP**, **Azure**, and **on-premises** targets.

---

## Directory Layout

```text
development/
├── README.md                         # Complete step-by-step workflow & operations guide
├── .env.example                      # Template for gitignored `development/.env` (synced to GitHub via `gh` by setup.sh)
├── gpu-dev-machine/                  # Podman + podman-compose stack (vLLM DeepSeek-V4.1-Flash, LiteLLM, DeepSeek Harness, reverse tunnels)
│   ├── compose.yml                   # Stack definition; all model, TP, KV-cache & CPU-offload parameters live directly here
│   ├── .env.example                  # Runtime .env template written on the GPU VM (mode 0600) by deploy_gpu_stack.sh
│   ├── compose.yml → vllm-server     # vLLM OpenAI server (image only) serving full unquantized DeepSeek-V4.1-Flash
│   ├── litellm/                      # LiteLLM OpenAI-compatible proxy (:4000) backed by vllm-server (:8000)
│   ├── deepseek-harness/             # DeepSeek Harness web UI (:3080 Caddy front with password /login -> 127.0.0.1:3081) pointed at LiteLLM
│   └── reverse-tunnel/               # Optional autossh reverse-SSH tunnel containers for LiteLLM & DeepSeek Harness
├── infra/
│   ├── gcp/                          # GCP Terraform: Stateless Multi-Zone Regional MIG (Spot/Standard, custom/default VPC) + Same-Region GCS Cache Bucket + Secret Manager runner bootstrap + ephemeral 3 TB Hyperdisk
│   ├── azure/                        # (Planned) Azure GPU VM Terraform
│   └── on-prem/                      # (Planned) On-prem GPU host configuration
└── scripts/
    ├── setup.sh                      # Syncs `development/.env` to GitHub via `gh` (zero-SSH on GCP incl. Regional MIG `--status`; SSH runner setup for azure/on-prem)
    ├── deploy.sh                     # Creates/manages the GPU machine infrastructure (--provider=<gcp|azure|on-prem>, region-level capacity cycling)
    └── deploy_gpu_stack.sh           # Syncs & deploys development/gpu-dev-machine via podman-compose + triggers `gpu-gcs-sync --fast` (CI or local)
```

---

## Architecture (`--provider=gcp`)

On GCP, `development/` uses a **zero-SSH single-VM Stateless Multi-Zone Regional Managed Instance Group (`dev-gpu-mig`)** paired with a **same-region GCS cache bucket (`<project>-<prefix>-cache-<region>`)** and no separate controller VM. All setup, cache sync, and orchestration work over outbound HTTPS (`443`):

```mermaid
flowchart LR
  W["Workstation (gcloud + gh + setup.sh + deploy.sh)"] -- "gh variable/secret set" --> GH["GitHub Repo & 'gpu' Environment"]
  W -- "Terraform + Secret Manager payload" --> SM["Secret Manager: dev-gpu-runner-bootstrap"]
  GH <-- "Long-poll jobs & git clone (outbound HTTPS 443)" --> G

  subgraph GCP["GCP Region (Custom VPC 10.10.0.0/24 or existing default VPC)"]
    SM -. "secretAccessor (dev-gpu-vm-sa)" .-> G
    MIG["Stateless Multi-Zone Regional MIG: dev-gpu-mig (target_size = 1, ANY shape, allow_changing_zone = YES)"] -- "Cross-zone Spot/repair placement" --> G["dev-gpu-vm-* : g4-standard-192 (SPOT or STANDARD, 50 GB boot)"]
    D[("Ephemeral Data Disk 'data': 3000 GB hyperdisk-balanced (/mnt/data, auto_delete=true)")]
    G --- D
    GCS[("Same-Region GCS Cache Bucket: <project>-dev-gpu-cache-<region> ($0 regional transfer)")]
    G <-- "Boot restore + 15m timer + shutdown --fast flush" --> GCS
  end
```

| Component | Default Spec | Lifecycle & Role |
| :--- | :--- | :--- |
| **Stateless Multi-Zone Regional MIG** (`dev-gpu-mig`) | `google_compute_region_instance_group_manager`, `target_size = 1`, `distribution_policy_target_shape = "ANY"`, `on_repair { allow_changing_zone = "YES" }`, `replacement_method = "SUBSTITUTE"`, `instance_redistribution_type = "NONE"` | Spans all GPU-capable zones in the target region (overridable via `--zones=z1,z2` or `--zone=z1`). Places a single GPU VM in whichever zone has capacity and automatically fails over across zones on Spot preemption or repair without orphaned disks. |
| **Autohealing** (`dev-gpu-health`) | `google_compute_health_check` HTTP `:8090/health` every 60 s, unhealthy after 5 failures; MIG `auto_healing_policies` (`initial_delay_sec = 900`); firewall `*-allow-health-checks` opens only `8090` to Google's health checkers (`35.191.0.0/16`, `130.211.0.0/22`) | `gpu-health` (stdlib Python, `gpu-health.service`, installed first by the startup script) checks **only the GitHub Actions runner service**: healthy for the first 30 min of every boot, then only while the runner service is active. A VM whose boot hangs before the runner starts, whose runner dies, or that stops answering is recreated in ~5 min. Containers (vLLM, LiteLLM, harness, tunnels) are deliberately **not** checked (a stack that fails to start would just loop recreations); `deploy_gpu_stack.sh` reports those. Needs `enable_ingress_firewalls = true`; disable with `enable_autohealing = false`. |
| **Same-Region GCS Cache Bucket** (`<project>-<prefix>-cache-<region>`) | `google_storage_bucket.gpu_cache`, `STANDARD` storage class in `upper(var.region)`, `uniform_bucket_level_access = true`, `public_access_prevention = "enforced"`, `roles/storage.objectAdmin` for `dev-gpu-vm-sa` | Persists `actions-runner-state/` (`.runner`, `.credentials`, `.credentials_rsaparams`), `stacks/gpu-dev-machine/` (`compose.yml`, `.env`), `reverse-tunnel/`, `deepseek-harness/` (`dsh-home`, `workspace`), and `huggingface/` model weights across cross-zone VM recreations (`$0` same-region GCS ↔ GCE transfer). Synced on boot, every 15 min via `gpu-gcs-sync.timer`, right after `deploy_gpu_stack.sh`, and on shutdown (`gpu-gcs-sync --fast`). |
| **GPU VM Template** (`dev-gpu-tpl-*`) | `g4-standard-192` (4× NVIDIA RTX PRO 6000, 192 vCPUs, 720 GB RAM), Ubuntu 24.04, `50 GB` `hyperdisk-balanced` boot disk | Configurable via `--spot` (`SPOT`, `instance_termination_action = "STOP"`, default) or `--no-spot` (`STANDARD` on-demand). On boot, `startup-script` installs Canonical's prebuilt Secure-Boot-signed NVIDIA open driver (`nvidia-driver-*-open` + `linux-modules-nvidia-*-open-$(uname -r)`), Podman, and NVIDIA Container Toolkit CDI, restores runner state, stack config, and model cache from GCS, self-starts/registers `gcp-gpu-runner`, enables `gpu-gcs-sync.timer`, and auto-resumes any deployed stack. |
| **Ephemeral Data Disk** (`device_name = "data"`) | `3000 GB` `hyperdisk-balanced` (`auto_delete = true`, `8,000 IOPS / 750 MiB/s`) | Formatted (`ext4`) and mounted at `/mnt/data` on each VM boot with 16 MiB readahead for fast safetensors loading; holds local `/mnt/data/actions-runner`, `/mnt/data/containers/storage`, `/mnt/data/vllm-cache`, `/mnt/data/huggingface`, `/mnt/data/deepseek-harness`, `/mnt/data/reverse-tunnel`, and `/mnt/data/stacks/gpu-dev-machine`, and is automatically deleted with the VM when failing over across zones. |
| **Runner Bootstrap Secret** (`dev-gpu-runner-bootstrap`) | GCP Secret Manager (`secretAccessor` for `dev-gpu-vm-sa` only) | Holds JSON (`github_repo`, `runner_name`, `runner_labels`, `runner_token`, `runner_pat`) passed via `TF_VAR_*` by `deploy.sh`. Used for initial registration and fallback when GCS `actions-runner-state/` is absent or invalid. Never exposed in Terraform CLI args or logs. |
| **Networking, IAM & Firewall** | Custom VPC (`10.10.0.0/24`) or `default` VPC (`--use-default-vpc`); `dev-gpu-vm-sa` | Ephemeral external IP on `nic0` by default (`enable_external_ip = true`), or Cloud Router + Cloud NAT when disabled. Outbound HTTPS (`443`) is allowed; direct public ingress is disabled by default (`enable_public_ingress = false`), with optional IAP TCP `22` (`35.235.240.0/20`) for admin debugging only. The only other ingress is the autohealing probe port (`8090`) from Google's health-check ranges. |

---

## Step-by-Step Workflow

### Step 1 — Authenticate `gcloud` & `gh` CLI

No service-account JSON keys, cloud credentials, or hardcoded GCP project IDs are stored in the repository or in GitHub. Everything runs from your logged-in workstation CLIs:

```bash
# 1. Authenticate gcloud and select the target GCP project
gcloud auth login
gcloud config set project <YOUR_GCP_PROJECT_ID>

# Verify active account & project
gcloud config get-value account
gcloud config get-value project

# If using a corporate *@google.com account (CBA/mTLS-bound access tokens),
# also log in with Application Default Credentials once — deploy.sh detects
# *@google.com automatically and routes Terraform through ADC:
gcloud auth application-default login

# 2. Authenticate GitHub CLI (`setup.sh` and `deploy.sh` use `gh` to sync secrets/vars & mint runner tokens)
gh auth login
gh auth status
```

---

### Step 2 — Lock Down Public PRs, Configure `development/.env`, & Sync GitHub (`setup.sh`)

#### 2.1 Lock Down Public PRs First (Before Attaching a Self-Hosted Runner)

If the target repository is **public**, lock down Pull Requests in GitHub before attaching the runner so external forks can never execute `runs-on: self-hosted`:

1. **Disable or Restrict Public PRs:**
   - **Settings → General → Features → Pull requests** → either **uncheck Pull requests** completely or **restrict pull request creation to collaborators only**.
2. **Fork Workflow Approval Gate (if PRs stay enabled):**
   - **Settings → Actions → General → Fork pull request workflows from outside collaborators** → select **"Require approval for all external contributors"**.
3. **Protected `gpu` Environment Gate:**
   - **Settings → Environments → `gpu`** → restrict **Deployment branches** to `Selected branches: main` and add yourself under **Required reviewers** (`setup.sh` creates the `gpu` environment automatically if missing, without overwriting protection rules you configure).
4. **Workflow YAML (`on:` triggers):**
   - Workflows using `runs-on: self-hosted` (such as [`.github/workflows/deploy-gpu-machine.yml`](../.github/workflows/deploy-gpu-machine.yml)) must trigger only on `workflow_dispatch` or `push: branches: [main]`—never `pull_request` or `pull_request_target`.

#### 2.2 Create & Fill In `development/.env`

Copy [`.env.example`](./.env.example) to `development/.env` (gitignored and enforced `chmod 600`):

```bash
cp -n development/.env.example development/.env
chmod 600 development/.env
```

All supported keys in `development/.env`:

| Key in `development/.env` | Default in `.env.example` | Used / Synced Where | Purpose |
| :--- | :--- | :--- | :--- |
| **`GITHUB_REPO`** | `vitorecomp/personal-infra` | `gh --repo` + Secret Manager payload | Target `owner/repo` for variables, secrets, and runner self-registration. |
| **`GITHUB_ENV`** | `gpu` | `gh --env` | GitHub Environment holding GPU stack secrets and variables. |
| **`GH_TOKEN`** | *(empty)* | Local `gh` auth | Optional token override when `gh auth login` is not active (falls back to root `.env` `GH_TOKEN` / `GITHUB_TOKEN`). |
| **`GPU_RUNNER`** | `gcp-gpu` | **Repo Variable** `GPU_RUNNER` + runner label | Selects which runner pool executes `deploy-gpu-machine.yml` (`gcp-gpu`, `azure-gpu`, `on-prem-gpu`). |
| **`GPU_RUNNER_LABELS`** | `["self-hosted","linux","x64","gcp-gpu"]` | **Repo Variable** `GPU_RUNNER_LABELS` | Full JSON label array synced for `runs-on:`. |
| **`RUNNER_NAME`** / **`RUNNER_LABELS`** | `gcp-gpu-runner` / `self-hosted,linux,x64,gcp-gpu` | Secret Manager + runner config | Self-hosted runner name and comma-separated labels registered by the GPU VM on boot. |
| **`RUNNER_PAT`** | *(empty)* | `TF_VAR_runner_pat` → Secret Manager | Optional repo-scoped Fine-Grained PAT (**Administration: Read & Write**). When empty, `deploy.sh` auto-mints a 1-hour registration token via `gh api` and `gs://$CACHE_BUCKET/actions-runner-state/` persists `.runner` / `.credentials` across cross-zone Spot recreations. |
| **`PROJECT_ID`** | *(empty)* | `deploy.sh` / `setup.sh --status` | Optional GCP project override (defaults to active `gcloud config get-value project`). |
| **`REGION`** / **`ZONES`** / **`ZONE`** | *(empty)* | `deploy.sh` / `setup.sh --status` | Optional GCP region (default `europe-west4`), comma-separated `ZONES` list within `REGION` (default: all GPU-capable zones in the region), and optional single-`ZONE` override. |
| **`CACHE_BUCKET_NAME`** | *(empty)* | GCP Terraform (`cache_bucket_name`) | Optional same-region GCS cache bucket name override (defaults to `<project_id>-<name_prefix>-cache-<region>`). |
| **`USE_SPOT`** | `true` | GCP Terraform (`use_spot`) | `true` provisions a Spot GPU VM auto-healed across zones by the Regional MIG; `false` provisions a Standard on-demand GPU VM. |
| **`USE_DEFAULT_VPC`** / **`DEFAULT_VPC_NAME`** | `false` / `default` | GCP Terraform (`use_default_vpc`) | Set `true` (or pass `--use-default-vpc`) to attach the MIG to an existing VPC instead of creating `dev-gpu-vpc`. |
| **`ENABLE_INGRESS_FIREWALLS`** | `true` | GCP Terraform (`enable_ingress_firewalls`) | Manage VPC ingress firewall rules in Terraform (set `false` if external org policies manage VPC ingress). |
| **`SSH_PROXY_CIDRS`** | `35.235.240.0/20` | GCP VPC firewall (`allow-iap-ssh`) | Proxy CIDR ranges allowed on TCP `22` for optional admin debugging (defaults to GCP IAP). |
| **`LITELLM_MASTER_KEY`** | `__generate__` | **`gpu` Secret** `LITELLM_MASTER_KEY` | Master Bearer key for `litellm` and `deepseek-harness`. When `__generate__` (or empty), `setup.sh` generates a random `sk-...` key once, **saves it back into `development/.env` (`0600`)**, and uploads it to GitHub Secrets. |
| **`HF_TOKEN`** | *(empty)* | **`gpu` Secret** `HF_TOKEN` *(if set)* | Optional Hugging Face read token to avoid rate limits pulling `deepseek-ai/DeepSeek-V4.1-Flash`. |
| **`HARNESS_USER`** / **`HARNESS_PASSWORD`** | `admin` / `__generate__` | **`gpu` Variable** / **Secret** | Login for `http://127.0.0.1:3080/login` (see *Harness login*); the password is generated once, saved back to `development/.env` (`0600`) and uploaded. URL-safe characters only. |
| **`ENABLE_REVERSE_TUNNELS`** | `false` | **`gpu` Variable** `ENABLE_REVERSE_TUNNELS` | `true` starts `litellm-tunnel` + `deepseek-harness-tunnel`; `false` starts only `vllm-server`, `litellm`, and `deepseek-harness`. |
| **`TUNNEL_SSH_HOST`** | *(empty)* | **`gpu` Variable** `TUNNEL_SSH_HOST` | Bastion/workstation hostname or IP receiving the reverse SSH tunnels (required when `ENABLE_REVERSE_TUNNELS=true`). |
| **`TUNNEL_SSH_PORT`** / **`TUNNEL_SSH_USER`** | `22` / *(empty)* | **`gpu` Variables** | SSH port and username on `TUNNEL_SSH_HOST`. |
| **`TUNNEL_SSH_KEY_FILE`** | `__generate__` | **`gpu` Secret** `TUNNEL_SSH_PRIVATE_KEY` | When `__generate__`, `setup.sh` creates `~/.ssh/gpu_tunnel_ed25519` (+ `.pub`), saves its path in `development/.env`, and uploads the private key as `TUNNEL_SSH_PRIVATE_KEY`. |
| **`TUNNEL_KNOWN_HOSTS`** | *(empty)* | **`gpu` Variable** `TUNNEL_KNOWN_HOSTS` | Pinned `ssh-keyscan` line(s) **or** a local `known_hosts` file path. |
| **`TUNNEL_BIND_ADDRESS`** | `127.0.0.1` | **`gpu` Variable** `TUNNEL_BIND_ADDRESS` | Address bound on `TUNNEL_SSH_HOST` (`127.0.0.1` or `0.0.0.0`). |
| **`REMOTE_LITELLM_PORT`** / **`REMOTE_HARNESS_PORT`** | `4000` / `3080` | **`gpu` Variables** | Remote ports opened on `TUNNEL_SSH_HOST` forwarding to `litellm:4000` and `deepseek-harness:3080`. |
| **`LITELLM_TUNNEL_SSH_*`** / **`HARNESS_TUNNEL_SSH_*`** | *(empty)* | **`gpu` Variables** *(if set)* | Optional per-tunnel `_HOST`, `_PORT`, `_USER` overrides (inherit `TUNNEL_SSH_*` when empty). |
| **`GPU_TARGET_MODE`** | `local` | **`gpu` Variable** `GPU_TARGET_MODE` | Runner-to-GPU target mode: `local` (default on GCP Regional MIG since the runner runs directly on the GPU VM), `auto`, or `ssh` (external hosts). |
| **`GPU_SSH_HOST`** / **`GPU_SSH_KEY_FILE`** / **`GPU_SSH_KNOWN_HOSTS`** | *(empty)* | **`gpu` Vars & Secret** `GPU_SSH_PRIVATE_KEY` | Non-GCP SSH target and private key file path when `GPU_TARGET_MODE=ssh`. |
| **`TRIGGER_DEPLOY`** | `false` | Post-setup `gh workflow run` | Set `true` (or pass `--trigger-deploy`) to immediately dispatch `deploy-gpu-machine.yml` after setup finishes. |

#### 2.3 Run `setup.sh --provider=gcp` (Purely Local `gh` Sync, Zero SSH)

On GCP (`--provider=gcp` without `--host`), [`setup.sh`](./scripts/setup.sh) **never opens SSH**—it only syncs `development/.env` to GitHub via `gh`, and inspects `--status` / executes `--remove` via `gh api` and `gcloud`:

```bash
# 1. Preview all `gh` variable/secret sync commands (safe, read-only)
./development/scripts/setup.sh --provider=gcp --dry-run

# 2. Generate any `__generate__` secrets locally and sync Repo & `gpu` Environment via `gh`
./development/scripts/setup.sh --provider=gcp

# Check GitHub runner online/offline state & GCP Regional MIG instances anytime (zero SSH)
./development/scripts/setup.sh --provider=gcp --status
```

> **Note:** SSH runner installation in `setup.sh` is retained for `--provider=azure`, `--provider=on-prem`, or when an explicit `--host=user@ip` is provided (e.g., `./development/scripts/setup.sh --provider=on-prem --host=dev@192.0.2.10`).

---

### Step 3 — Preview & Provision the Regional MIG (`deploy.sh`)

#### 3.1 Preview (`--dry-run`)

Always run `--dry-run` first to verify your resolved `gcloud` account, credential mode (`gcloud` token vs. ADC), active project, region/zones, GCS cache bucket, Spot/Standard setting, VPC mode, and Terraform commands:

```bash
./development/scripts/deploy.sh --provider=gcp --dry-run
./development/scripts/deploy.sh --provider=gcp --no-spot --use-default-vpc --dry-run
./development/scripts/deploy.sh --provider=gcp --region=europe-west2 --zones=europe-west2-b,europe-west2-c --dry-run
./development/scripts/deploy.sh --provider=gcp --cycle-regions --loop=5 --dry-run
```

#### 3.2 Provision the Multi-Zone Regional MIG (`deploy.sh`)

```bash
# Default: Spot GPU VM in the Regional MIG (custom VPC, spans all GPU zones in europe-west4)
./development/scripts/deploy.sh --provider=gcp

# Standard (on-demand) GPU VM attached to the existing 'default' VPC
./development/scripts/deploy.sh --provider=gcp --no-spot --use-default-vpc

# Pin specific zones and/or override the regional GCS cache bucket name
./development/scripts/deploy.sh --provider=gcp --region=europe-west2 --zones=europe-west2-b,europe-west2-c --cache-bucket=my-gpu-cache

# Cycle across all GPU-capable regions every 5 minutes until Spot capacity opens
./development/scripts/deploy.sh --provider=gcp --spot --cycle-regions --loop=5

# Or cycle through a specific priority list of regions
./development/scripts/deploy.sh --provider=gcp --regions=europe-west4,europe-west2,europe-west1,us-central1,us-east4 --loop=5
```

**What `deploy.sh --provider=gcp` handles automatically:**
1. **Smart Credential Selection (`--adc` / `--gcloud-token`):** Uses `GOOGLE_OAUTH_ACCESS_TOKEN` for standard accounts, and automatically switches to Application Default Credentials (`~/.config/gcloud/application_default_credentials.json`) for `*@google.com` CBA accounts.
2. **API Enablement & Per-Project Workspace:** Enables `compute.googleapis.com`, `secretmanager.googleapis.com`, `storage.googleapis.com`, `iap.googleapis.com`, `oslogin.googleapis.com`, and `iam.googleapis.com`, initializes Terraform, and selects/creates workspace `development/infra/gcp/terraform.tfstate.d/<project_id>/`.
3. **Zero-Leak Runner Bootstrap Auth:** Uses `RUNNER_PAT` if set in `development/.env`, or auto-mints a 1-hour GitHub runner registration token via `gh api`, passing it exclusively via `TF_VAR_runner_pat` / `TF_VAR_runner_token` into GCP Secret Manager (`dev-gpu-runner-bootstrap`).
4. **Regional MIG Provisioning & Region Cycling:** Queries `gcloud compute machine-types list` once to discover all GPU-capable zones per region, applies the Stateless Multi-Zone Regional MIG (`dev-gpu-mig`, `target_size = 1`, `distribution_policy_target_shape = "ANY"`, `allow_changing_zone = "YES"`) + same-region GCS cache bucket (`google_storage_bucket.gpu_cache`), and polls `gcloud compute instance-groups managed list-instances --region=<region>` for up to 90s (`18 * 5s`) to verify `RUNNING` status (showing whichever zone GCE selected). On `QUOTA_EXCEEDED` or region exhaustion it cleans up the probe MIG/template (and empty probe bucket) and tries the next region (or leaves the MIG active on the final candidate when `--stage-terminated` is enabled / `--loop` is not set).
5. **Zero-SSH Self-Registration, GCS Cache Restore & Sync on Boot (`startup-script`):** Logged to `/var/log/gpu-mig-bootstrap.log` on the GPU VM:
   - Formats `/dev/disk/by-id/google-data` (`ext4`, `auto_delete = true`) and mounts it at `/mnt/data` (`nofail`) with 16 MiB readahead.
   - Points Podman `graphroot` at `/mnt/data/containers/storage` so container images never fill the 50 GB boot disk.
   - Creates `github-runner` with passwordless sudo and symlinks `/opt/actions-runner -> /mnt/data/actions-runner`.
   - Installs OS packages, Canonical's prebuilt Secure-Boot-signed NVIDIA open driver (`nvidia-driver-*-open` + `linux-modules-nvidia-*-open-$(uname -r)`), `nvidia-container-toolkit` (`/etc/cdi/nvidia.yaml` at CDI `0.6.0`), `netavark` + `aardvark-dns`, Podman, `podman-compose`, and `actions-runner-linux-x64`.
   - Writes `/etc/gpu-cache-bucket` and installs `/usr/local/bin/gpu-gcs-sync` + `gpu-gcs-sync.service` + 15-minute `gpu-gcs-sync.timer` (plus shutdown flush via `gpu-gcs-sync --fast`).
   - Restores `actions-runner-state/` (`.runner`, `.credentials`, `.credentials_rsaparams`) from `gs://$CACHE_BUCKET` before registering; if absent or invalid, fetches `dev-gpu-runner-bootstrap` from Secret Manager, registers fresh with `--replace`, and uploads the new credentials to `gs://$CACHE_BUCKET/actions-runner-state/`.
   - Restores `stacks/gpu-dev-machine/`, `reverse-tunnel/`, `deepseek-harness/`, and `huggingface/` model cache from `gs://$CACHE_BUCKET` (`$0` same-region GCS → GCE transfer), and auto-resumes any previously deployed Podman stack in `/mnt/data/stacks/gpu-dev-machine`.

Verify the GPU VM and GitHub runner are online (zero SSH):

```bash
./development/scripts/setup.sh --provider=gcp --status
```

---

### Step 4 — Deploy the Podman Stack & Cross-Zone Spot Failover

Once `./development/scripts/setup.sh --provider=gcp --status` shows your self-hosted runner (`gcp-gpu-runner`) is **online**:

1. **Deploy via GitHub Actions:** Push a change under `development/gpu-dev-machine/**` to `main`, trigger [`.github/workflows/deploy-gpu-machine.yml`](../.github/workflows/deploy-gpu-machine.yml) manually (`workflow_dispatch`), or run:
   ```bash
   ./development/scripts/setup.sh --provider=gcp --sync-github-only --trigger-deploy
   ```
2. **Direct Local Execution (`GPU_TARGET_MODE=local`):** Because the runner runs directly on the GPU VM in `dev-gpu-mig`, [`deploy_gpu_stack.sh`](./scripts/deploy_gpu_stack.sh) executes locally:
   - Ensures `/mnt/data` directories, Podman storage config (`netavark` + `pids_limit = 65536`), NVIDIA driver, and `/etc/cdi/nvidia.yaml` exist.
   - Syncs `development/gpu-dev-machine/` to `/mnt/data/stacks/gpu-dev-machine`, writes mode-`0600` `.env` (plus optional tunnel SSH key), and runs `podman-compose -f compose.yml up -d --build`.
   - Immediately runs `sudo /usr/local/bin/gpu-gcs-sync --fast` (when present) so newly deployed `.env`, `compose.yml`, and reverse-tunnel keys are persisted to the regional GCS cache bucket right away.
3. **Automatic Spot Preemption & Cross-Zone Failover Recovery:**
   - When a Spot VM is preempted or repaired, `shutdown-script` stops Podman containers gracefully (`podman stop -t 10 --all`), flushes small state (`stacks/gpu-dev-machine/`, `reverse-tunnel/`, `deepseek-harness/`, `actions-runner-state/`) via `/usr/local/bin/gpu-gcs-sync --fast`, and unmounts `/mnt/data` (`auto_delete = true` deletes the ephemeral Hyperdisk cleanly with zero orphaned disks). Meanwhile, the 15-minute `gpu-gcs-sync.timer` keeps `huggingface/` model weights synced to GCS while the VM is running.
   - `dev-gpu-mig` (`distribution_policy_target_shape = "ANY"`, `on_repair { allow_changing_zone = "YES" }`, `replacement_method = "SUBSTITUTE"`) schedules a replacement VM in any available GPU zone within the region—even if the original zone is out of capacity.
   - On boot in the new zone, `startup-script` restores `actions-runner-state/` from `gs://$CACHE_BUCKET` (reusing preserved `.credentials` even after the 1-hour registration token expires, or falling back to Secret Manager), starts `gcp-gpu-runner`, pulls `stacks/gpu-dev-machine/`, `reverse-tunnel/`, `deepseek-harness/`, and `huggingface/` from the same-region GCS bucket at `$0` transfer cost, enables `gpu-gcs-sync.timer`, and **automatically runs `podman-compose up -d`** without requiring a new CI workflow run.

| Service in [`compose.yml`](./gpu-dev-machine/compose.yml) | GPU VM Port | Local Storage on `/mnt/data` & Regional GCS Cache | Role & Configuration |
| :--- | :--- | :--- | :--- |
| **`vllm-server`** | `127.0.0.1:8000` (OpenAI API) | `/mnt/data/huggingface` *(synced ↔ `gs://$CACHE_BUCKET/huggingface/`)* + `/mnt/data/vllm-cache` *(local JIT cache)* | `vllm serve` serving full unquantized `deepseek-ai/DeepSeek-V4.1-Flash` (`--tensor-parallel-size=4`, `--cpu-offload-gb=48`, engram CPU offload, `--kv-cache-dtype=fp8`, `--max-model-len=65536`). **All model & offload parameters are version-controlled directly in [`compose.yml`](./gpu-dev-machine/compose.yml)**—not pipeline variables. |
| **`litellm`** | `127.0.0.1:4000` | — | OpenAI-compatible gateway authenticated with `LITELLM_MASTER_KEY`, routing model aliases to `http://vllm-server:8000/v1`. |
| **`deepseek-harness`** | `127.0.0.1:3080` | `/mnt/data/deepseek-harness/{dsh-home,workspace}` *(synced ↔ `gs://$CACHE_BUCKET/deepseek-harness/`)* | Runs `@deepseek-ai/dsh` web UI (`127.0.0.1:3081` behind a Caddy front with the password-protected `/login`; served on container `0.0.0.0:3080` by Caddy), pre-wired to `http://litellm:4000/v1` with `LITELLM_MASTER_KEY`. |
| **`litellm-tunnel`** *(optional)* | Outbound SSH | `/mnt/data/reverse-tunnel` *(synced ↔ `gs://$CACHE_BUCKET/reverse-tunnel/`)* | Started only when `ENABLE_REVERSE_TUNNELS=true`; `autossh` reverse-forwards `TUNNEL_SSH_HOST:REMOTE_LITELLM_PORT` → `litellm:4000`. |
| **`deepseek-harness-tunnel`** *(optional)* | Outbound SSH | `/mnt/data/reverse-tunnel` *(synced ↔ `gs://$CACHE_BUCKET/reverse-tunnel/`)* | Started only when `ENABLE_REVERSE_TUNNELS=true`; `autossh` reverse-forwards `TUNNEL_SSH_HOST:REMOTE_HARNESS_PORT` → `deepseek-harness:3080`. |

> **Optional Admin Debugging / Local Port-Forward via IAP:** If you disable reverse tunnels (`ENABLE_REVERSE_TUNNELS=false`) and want temporary local access or log inspection (`/var/log/gpu-mig-bootstrap.log`), inspect the active Regional MIG instance (and whichever zone GCE placed it in) and tunnel over IAP:
> ```bash
> eval "$(terraform -chdir=development/infra/gcp output -raw list_instances_command)"
> gcloud compute ssh <MIG_INSTANCE_NAME> \
>   --project="$(gcloud config get-value project)" \
>   --zone="<INSTANCE_ZONE>" \
>   --tunnel-through-iap \
>   -- -N -L 4000:127.0.0.1:4000 -L 3080:127.0.0.1:3080
> ```

---

## GitHub Variables & Secrets Reference

All items below are populated automatically from `development/.env` when you run `./development/scripts/setup.sh --provider=gcp`:

### 1. Repository Variables (`Settings → Secrets and variables → Actions → Variables`)

> **Why Repository-level?** GitHub Actions evaluates `runs-on:` before loading Environment variables, so runner pool selection lives in Repository Variables.

| Variable | Required | Default / Example | Description |
| :--- | :--- | :--- | :--- |
| **`GPU_RUNNER`** | **Recommended** | `gcp-gpu` *(or `azure-gpu`, `on-prem-gpu`)* | Controls which self-hosted runner pool executes `deploy-gpu-machine.yml` (`["self-hosted","linux","x64","<GPU_RUNNER>"]`). |
| **`GPU_RUNNER_LABELS`** | Optional | `["self-hosted","linux","x64","gcp-gpu"]` | Full JSON label array override for `runs-on:` if custom label combinations are needed instead of `GPU_RUNNER`. |

### 2. `gpu` Environment Secrets (`Settings → Environments → gpu → Environment secrets`)

| Secret | Required | Description |
| :--- | :--- | :--- |
| **`LITELLM_MASTER_KEY`** | **Yes** | Master Bearer key securing `litellm` and injected into `deepseek-harness` (auto-generated once by `setup.sh` when `LITELLM_MASTER_KEY=__generate__`). |
| **`TUNNEL_SSH_PRIVATE_KEY`** | When tunnels enabled | OpenSSH private key uploaded from `TUNNEL_SSH_KEY_FILE` in `development/.env`, used by `litellm-tunnel` and `deepseek-harness-tunnel`. |
| **`HF_TOKEN`** | Optional | Hugging Face read token to avoid rate limits when downloading `deepseek-ai/DeepSeek-V4.1-Flash`. |
| **`HARNESS_PASSWORD`** | Recommended | Password for the harness `/login` page (basic auth, user `HARNESS_USER`, default `admin`); generated once by `setup.sh` when `__generate__`. |
| **`GPU_SSH_PRIVATE_KEY`** | Optional (non-GCP) | SSH private key uploaded from `GPU_SSH_KEY_FILE` when `GPU_TARGET_MODE=ssh` targets an external `GPU_SSH_HOST`. |
| **`TUNNEL_SSH_HOST`**, **`TUNNEL_KNOWN_HOSTS`** (+ `LITELLM_`/`HARNESS_TUNNEL_SSH_HOST`, `GPU_SSH_HOST`, `GPU_SSH_KNOWN_HOSTS`) | When set | Host names/IPs and host keys of personal machines. `setup.sh` stores them as secrets (masked in this public repo's logs) and deletes same-named variables; the workflow falls back to variables. |

### 3. `gpu` Environment Variables (`Settings → Environments → gpu → Environment variables`)

> **Note:** Model, tensor-parallelism, and CPU-offload settings are intentionally **not** pipeline variables—edit [`development/gpu-dev-machine/compose.yml`](./gpu-dev-machine/compose.yml) to change them.

| Variable | Required | Default | Description |
| :--- | :--- | :--- | :--- |
| **`GPU_TARGET_MODE`** | Optional | `local` *(in `.env.example`; `auto` workflow fallback)* | Execution mode for `deploy_gpu_stack.sh`: `local` (default for self-registering GCP MIG runner), `auto`, or `ssh`. |
| **`ENABLE_REVERSE_TUNNELS`** | Optional | `false` *(or `true` if `TUNNEL_SSH_HOST` set)* | `true` starts `litellm-tunnel` + `deepseek-harness-tunnel`; `false` starts only `vllm-server`, `litellm`, and `deepseek-harness`. |
| **`TUNNEL_SSH_HOST`** | When tunnels enabled | — | *(Now synced as a secret, see above.)* Remote host receiving the reverse-forwarded ports. |
| **`TUNNEL_SSH_USER`** | When tunnels enabled | — | SSH username on `TUNNEL_SSH_HOST`. |
| **`TUNNEL_SSH_PORT`** | Optional | `22` | SSH port on `TUNNEL_SSH_HOST`. |
| **`TUNNEL_KNOWN_HOSTS`** | Optional | *(accept-new TOFU)* | *(Now synced as a secret.)* Pinned `ssh-keyscan` line(s) for `TUNNEL_SSH_HOST` (enforces `StrictHostKeyChecking=yes`). |
| **`TUNNEL_BIND_ADDRESS`** | Optional | `127.0.0.1` | Interface bound on `TUNNEL_SSH_HOST` (`127.0.0.1` or `0.0.0.0`). |
| **`REMOTE_LITELLM_PORT`** | Optional | `4000` | Port opened on `TUNNEL_SSH_HOST` forwarding to `litellm:4000`. |
| **`REMOTE_HARNESS_PORT`** | Optional | `3080` | Port opened on `TUNNEL_SSH_HOST` forwarding to `deepseek-harness:3080`. |
| **`LITELLM_TUNNEL_SSH_HOST`** / `_PORT` / `_USER` | Optional | Inherits `TUNNEL_SSH_*` | Optional per-tunnel destination override for `litellm-tunnel`. |
| **`HARNESS_TUNNEL_SSH_HOST`** / `_PORT` / `_USER` | Optional | Inherits `TUNNEL_SSH_*` | Optional per-tunnel destination override for `deepseek-harness-tunnel`. |
| **`GPU_SSH_HOST`** / **`GPU_SSH_KNOWN_HOSTS`** | Optional | — | Target `user@host` and `known_hosts` when `GPU_TARGET_MODE=ssh`. |

---

## Step 5 — Day-2 Operations (Pause/Scale, Switch Spot/Standard, Rotate Secrets, Destroy)

### Pause GPU Compute Billing While Preserving Cached Weights & Configs in GCS
Because the ephemeral `3000 GB` Hyperdisk uses `auto_delete = true` and persistent state lives in the same-region GCS cache bucket (`google_storage_bucket.gpu_cache`), scaling the Regional MIG to `0` deletes both the GPU VM and the Hyperdisk (zero GPU compute and zero Hyperdisk spend while paused) while retaining `huggingface/`, `stacks/gpu-dev-machine/`, `reverse-tunnel/`, `deepseek-harness/`, and `actions-runner-state/` in `gs://<cache-bucket>`:

```bash
# 1. Optional: flush any brand-new model weights to GCS before pausing (configs flush automatically via shutdown-script)
#    On the GPU VM: sudo /usr/local/bin/gpu-gcs-sync

# 2. Pause (scale Regional MIG to 0 — stops GPU compute & Hyperdisk billing)
gcloud compute instance-groups managed resize dev-gpu-mig \
  --size=0 \
  --region="$(terraform -chdir=development/infra/gcp output -raw region)" \
  --project="$(gcloud config get-value project)"

# 3. Resume later (either scale back to 1 or re-run deploy.sh)
./development/scripts/deploy.sh --provider=gcp
```

### Switch Between Spot and Standard (On-Demand) Without Losing State
The Regional MIG `update_policy` uses `replacement_method = "SUBSTITUTE"`, replacing the VM instance from the new template while the startup script restores cached weights, runner credentials, and stack config from the regional GCS bucket:

```bash
# Switch to Standard on-demand
./development/scripts/deploy.sh --provider=gcp --no-spot

# Switch back to Spot
./development/scripts/deploy.sh --provider=gcp --spot
```

### Use LiteLLM & the DeepSeek Harness from `personal-host` (private)

The reverse tunnels publish `litellm:4000` and `deepseek-harness:3080` on **loopback** of the always-on GCE VM
`personal-host` (the blog/edge VM). Nothing is exposed to the internet: use them from a shell on that VM, or
from your workstation through an SSH port-forward to it.

```bash
# On personal-host
curl -s http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
curl -s http://127.0.0.1:3080/ >/dev/null && echo "harness up"
# From the workstation (harness UI at http://127.0.0.1:3080, LiteLLM at http://127.0.0.1:4000)
ssh -N -L 3080:127.0.0.1:3080 -L 4000:127.0.0.1:4000 ubuntu@<vm-ip>
```

One-time setup:

```bash
# 1. personal-host: a no-shell `tunnel` user whose key may only open 127.0.0.1:4000 and 127.0.0.1:3080
python3 cloud/scripts/bootstrap_vm.py --host ubuntu@<vm-ip> --provider gce --deploy-pubkey-file ~/.ssh/taiga_deploy.pub \
  --tunnel-pubkey-file ~/.ssh/gpu_tunnel_ed25519.pub --swap-gb 3 --backup-stack personal-blog --backup-stack taiga
# 2. development/.env: ENABLE_REVERSE_TUNNELS=true, TUNNEL_SSH_HOST=<vm-ip>, TUNNEL_SSH_USER=tunnel,
#    TUNNEL_BIND_ADDRESS=127.0.0.1, TUNNEL_KNOWN_HOSTS="<vm-ip> ssh-ed25519 ..." ; then sync and deploy:
./development/scripts/setup.sh --provider=gcp
```

Both ports are closed while the GPU machine is stopped or preempted; autossh reconnects when it is back.

**Harness login.** Open `http://127.0.0.1:3080/login` (on personal-host, or through
`ssh -L 3080:127.0.0.1:3080 ubuntu@<vm-ip>`), enter `HARNESS_USER` / `HARNESS_PASSWORD` from `development/.env`
(HTTP basic auth), and you land in the UI. Behind it: dsh mints a random launch token per process that sets a signed
session cookie (30 days; the signing secret persists in `dsh-home/.credentials.yaml`, so restarts keep you logged in).
A Caddy front in the harness container (replacing socat on :3080) captures the token at startup and `/login` redirects
to it only after the password; everything else is proxied to dsh, HTTP and WebSocket, still guarded by its cookie.
`setup.sh` generates `HARNESS_PASSWORD` once (`__generate__`) and syncs it as a `gpu` secret. Without it, `/login` is
disabled and the `dsh web:` URL in the container log (port 3081 there, use 3080) still works.

### Update Secrets / Tunnel Settings & Redeploy Stack
```bash
# Edit development/.env, sync to GitHub via `gh`, and trigger deploy-gpu-machine.yml:
./development/scripts/setup.sh --provider=gcp --sync-github-only --trigger-deploy
```

### Plan / Update Infrastructure Changes
```bash
./development/scripts/deploy.sh --provider=gcp --plan
./development/scripts/deploy.sh --provider=gcp --apply
```

### Cleanly Remove the Runner & Full Teardown (`--destroy`)
> **Warning:** The ephemeral `3000 GB` Hyperdisk (`auto_delete = true`) is deleted automatically when the VM is destroyed, whereas the regional GCS cache bucket (`google_storage_bucket.gpu_cache`) defaults to `cache_bucket_force_destroy = false` so cached Hugging Face weights and stack configs are not accidentally lost. Empty or delete `gs://<cache-bucket>` first (or pass `-var="cache_bucket_force_destroy=true"` to Terraform) if you want zero GCS storage billing after `deploy.sh --destroy`.

```bash
# 1. Unregister matching runner(s) via GitHub API (zero SSH)
./development/scripts/setup.sh --provider=gcp --remove

# 2. Destroy Terraform-managed GCP resources (Regional MIG, template, GCS bucket if empty, Secret Manager secret, VPC/NAT)
./development/scripts/deploy.sh --provider=gcp --destroy
```

---

## CLI Reference

### 1. [`deploy.sh`](./scripts/deploy.sh) — Machine Creation & Infrastructure

| Flag | Description |
| :--- | :--- |
| `--provider=<gcp\|azure\|on-prem>` | **(Required)** Target infrastructure folder under `development/infra/<provider>`. |
| `--apply` | Initialize and apply Terraform (default action). |
| `--plan` | Initialize and run `terraform plan` without applying. |
| `--validate` | Run `terraform init -backend=false` and `terraform validate`. |
| `--destroy` | Destroy Terraform-managed resources for the selected provider. |
| `--loop=<minutes>` | Retry `apply` every `<minutes>` minutes until live capacity succeeds (also accepts `--loop <min>` or `loop=<min>`). |
| `--dry-run` | Print resolved settings, API calls, and Terraform commands without executing. |
| `--env-file=<path>` | Path to `.env` file (default: `development/.env`). |
| `--project=<id>` | Override active `gcloud config` project (`gcp` only). |
| `--adc` / `--gcloud-token` | Force ADC or `gcloud` CLI token (auto-selects ADC for `*@google.com` CBA accounts and `gcloud` token otherwise). |
| `--region=<region>` | Target cloud region override (default: `REGION` in `.env`, `terraform.tfvars`, or `europe-west4`). |
| `--zones=z1,z2,...` | Comma-separated zones within `--region` for the multi-zone Regional MIG (default: `ZONES` in `.env`, or all GPU-capable zones in `--region`). |
| `--zone=<zone>` | Single-zone override (narrows `zones` to `[ZONE]` and derives `--region` from `${ZONE%-*}` if `--region` is omitted). |
| `--cache-bucket=<name>` | Optional same-region GCS cache bucket name override (default: `CACHE_BUCKET_NAME` in `.env`, or `<project_id>-<name_prefix>-cache-<region>`). |
| `--regions=r1,r2,...` | Comma-separated list of regions to cycle through for GPU capacity (`gcp`; each region spans all its GPU-capable zones). |
| `--cycle-regions` | Cycle through all GPU-capable regions until capacity is found (`gcp`; each region spans all its GPU-capable zones). |
| `--machine-type=<type>` | Override GPU VM machine type (default: `g4-standard-192`). |
| `--name-prefix=<prefix>` | Override resource prefix (default: `dev-gpu`). |
| `--spot` | **(Default)** Provision the GPU VM in the MIG as a Spot VM (`use_spot = true`). |
| `--no-spot`, `--standard` | Provision the GPU VM in the MIG as a Standard on-demand VM (`use_spot = false`). |
| `--use-default-vpc` / `--no-use-default-vpc` | Attach the MIG to the existing `default` VPC (`use_default_vpc = true`) or create a dedicated custom VPC (default; alias `--custom-vpc`). |
| `--default-vpc-name=<name>` | Existing VPC name when `--use-default-vpc` is set (default: `default`). |
| `--ssh-proxy-cidrs=c1,c2,...` | Proxy CIDRs allowed on TCP `22` for optional debugging (default: `35.235.240.0/20`). |
| `--ssh-hostname-template=<tpl>` | Optional SSH relay hostname template (`{instance}`, `{zone}`, `{project}`). |
| `--force-move` | Allow moving to another region even if a Regional MIG already exists in Terraform state. |
| `--no-stage-terminated` | Destroy pending MIG and exit 1 on stockout (default when `--loop` is set). |
| `--stage-terminated` | Keep MIG active on the final candidate on stockout (even when `--loop` is set). |
| `--auto-approve` / `--no-auto-approve` | Control `-auto-approve` on `terraform apply` / `destroy` (default: `--auto-approve`). |
| `--repo=<owner/repo>` | GitHub repository to register the runner against (default: `GITHUB_REPO` in `.env`). |
| `--runner-name=<name>` | Self-hosted runner name stored in Secret Manager (default: `RUNNER_NAME` in `.env`, else `<provider>-gpu-runner`). |
| `--runner-labels=l1,l2,...` | Comma-separated runner labels (default: `self-hosted,linux,x64,<GPU_RUNNER>`). |
| `--runner-user=<user>` | Non-root OS user created on the VM for the runner service (default: `github-runner`). |

### 2. [`setup.sh`](./scripts/setup.sh) — `development/.env` GitHub Sync & Runner Lifecycle

| Flag | Description |
| :--- | :--- |
| `--provider=<gcp\|azure\|on-prem>` | **(Required)** Target provider (`gcp` is 100% SSH-free unless `--host` is set; `azure`/`on-prem` use SSH). |
| `--env-file=<path>` | Path to `.env` configuration file (default: `development/.env`). |
| `--project=<id>` / `--region=<region>` / `--zone=<zone>` | GCP project, region (preferred for Regional MIG), and optional zonal fallback overrides for `--status` MIG inspection. |
| `--mig=<name>` / `--name-prefix=<prefix>` | GCP MIG name override (default: `<prefix>-mig`) and prefix override (default: `dev-gpu`) for `--status`. |
| `--host=<user@host>` / `--ssh-key=<path>` / `--known-hosts=<path>` | Explicit SSH target & key overrides (enables SSH runner setup for `azure`, `on-prem`, or custom hosts). |
| `--repo=<owner/repo>` | GitHub repository override (default: `GITHUB_REPO` in `.env`, else `vitorecomp/personal-infra`). |
| `--github-env=<name>` | GitHub Environment name for stack secrets & variables (default: `gpu`). |
| `--token=<token>` / `--pat=<pat>` | Explicit runner token or Fine-Grained PAT (SSH mode; auto-minted via `gh api` when omitted). |
| `--name=<name>` | Runner name in GitHub (default: `RUNNER_NAME` in `.env`, else `<provider>-gpu-runner`). |
| `--labels=l1,l2,...` | Comma-separated runner labels (default: `self-hosted,linux,x64,<GPU_RUNNER>`). |
| `--runner-user=<user>` / `--runner-dir=<dir>` / `--work-dir=<dir>` | Remote OS user (`github-runner`), install path (`/opt/actions-runner`), and work directory (`_work`) in SSH mode. |
| `--sync-github-only` | Only sync `development/.env` variables/secrets to GitHub via `gh`. |
| `--skip-github-sync` | Skip `gh variable/secret set` (SSH mode: only configure the remote runner). |
| `--trigger-deploy` | Dispatch `gh workflow run deploy-gpu-machine.yml` after setup finishes (or set `TRIGGER_DEPLOY=true` in `.env`). |
| `--status` | **GCP:** query `gh api` runners & Regional MIG instances (`--region=<region>`, zero SSH). **SSH mode:** check remote `systemd` service. |
| `--remove` | **GCP:** unregister matching runner(s) via `gh api` (zero SSH). **SSH mode:** stop & remove remote service. |
| `--dry-run` | Print resolved `gh` / API / SSH steps without mutating anything. |

### 3. [`deploy_gpu_stack.sh`](./scripts/deploy_gpu_stack.sh) — GPU Podman Stack Deployer

| Flag | Description |
| :--- | :--- |
| `--target-mode=<auto\|controller-ssh\|ssh\|local>` | Execution mode (default: `auto` → uses `local` on the GCP Regional MIG runner, or `ssh` if `GPU_SSH_HOST` is set; `.env.example` sets `GPU_TARGET_MODE=local`). |
| `--ssh-host=<user@host>` | Target SSH host when `--target-mode=ssh` (or env `GPU_SSH_HOST`). |
| `--stack-dir=<path>` | Destination stack directory on the GPU VM (default: `/mnt/data/stacks/gpu-dev-machine`). |
| `--wait-timeout=<seconds>` | Max seconds to wait for SSH in `controller-ssh` mode (default: `600`). |
| `--dry-run` | Print resolved target mode, synced env key names (never values), and compose commands (including post-deploy `gpu-gcs-sync --fast`) without mutating state. |
| `--no-wait-for-model` | Finish once the containers run (env `WAIT_FOR_MODEL=false`; workflow input `wait_for_model`). By default the deploy waits for `vllm-server` `/health`, fails fast with the root-cause log lines if it restarts or exits, and ends with one chat request through LiteLLM. After starting containers, `deploy_gpu_stack.sh` also runs `sudo /usr/local/bin/gpu-gcs-sync --fast` (when present) to persist the stack config to GCS immediately. |
| `--model-timeout=<seconds>` | Max wait for the model (default `10800`, repo variable `MODEL_READY_TIMEOUT_SEC`): a first start downloads ~475 GiB and loads it. |

#### What the deploy takes care of on the GPU host (found on a full-size replica, 2026-11-27)

| Symptom | Cause | Handling |
| :--- | :--- | :--- |
| `unresolvable CDI devices nvidia.com/gpu=all` | Podman 4.9 reads CDI specs only up to 0.6.0; `nvidia-ctk` writes 0.7.0 | spec rewritten as 0.6.0 (drops the render-node `additionalGids`) |
| tunnels log `connect_to litellm: unknown host`; LiteLLM cannot reach `vllm-server` | Podman 4.9's CNI fallback has no DNS | `netavark` + `aardvark-dns` (`containers.conf.d`) |
| model load ~80 min, disk at its IOPS cap with ~20 KiB reads | mmap page faults with the default 128 KiB readahead | 16 MiB readahead on the data disk (4.7x faster) |
| `ThreadPoolBuildError ... Resource temporarily unavailable` right after loading | 4 TP workers x 192 vCPUs over Podman's 2048-task limit | `pids_limit = 65536` + `RAYON_NUM_THREADS=16` |
| `block_kv == 32 or block_kv == 64` assert during CUDA graph capture | vLLM 0.33 used 128-token blocks for the DeepSeek-V4.1 indexer on SM120 (RTX PRO 6000) | `vllm/vllm-openai:v0.34.0` |
| `podman stop` takes minutes; old container revived after a recreate | a killed vLLM frees ~200 GiB of pinned memory slowly (28 min while the download saturated the disk) | wait out stops; converge from a clean teardown if compose config hashes differ |
| every start recompiles kernels | JIT caches in the container (CuTe-DSL's could not be created) | caches persisted in `/mnt/data/vllm-cache` (and in the GCS cache bucket) |
| `vllm-server` stays `unhealthy` although `/health` answers 200 | podman-compose 1.0.6 joins exec-form (`["CMD", ...]`) healthchecks into one `/bin/sh -c` string with broken quoting (`Syntax error: word unexpected`) | healthchecks with shell metacharacters use `CMD-SHELL`; the deploy prints podman's last check output when they disagree |
| chat check crashed on `message.content: null` | DeepSeek V4.1 can spend a small `max_tokens` budget on reasoning only | 256-token budget; any completion counts, `finish_reason` reported |

The ephemeral data disk is provisioned on each VM boot at **8,000 IOPS / 750 MiB/s** (`data_disk_iops` / `data_disk_throughput_mbps`; the old 3,060 / 200 capped a cold load at ~40 min, 4,000 IOPS measured 357 MB/s ≈ 20 min, 8,000 targets ~11 min; ≈ US$51/month pro-rated while the VM is running above the free 3,000 IOPS / 140 MiB/s in europe-west4). Because the Regional MIG deletes the ephemeral Hyperdisk with the VM (`auto_delete = true`), each new instance template revision automatically provisions a fresh disk with these performance settings.
