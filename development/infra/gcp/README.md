# GCP Development GPU VM — Always-On Standard Controller + Auto-Restarting Spot GPU VM

Terraform configuration that provisions:
1. A small always-on **`e2-small` (`STANDARD`, `100 GB` boot disk) Controller/Runner VM** (`dev-gpu-controller`) holding a **fixed Static External IP**, **fixed SSH host keys**, pre-installed **GitHub Actions runner dependencies** (`github-runner` user + `/opt/actions-runner`), and a `systemd` watchdog service (`gpu-watchdog.service`).
2. The **`g4-standard-192` (`SPOT`, 4× NVIDIA RTX PRO 6000, 192 vCPUs, 720 GB RAM)** development GPU VM (`dev-gpu-vm`) with its own **fixed Static External IP** (retained across `STOP`/`start` restarts), fixed internal IP (`10.10.0.11`), and a **persistent `3000 GB` Hyperdisk Balanced volume (`/mnt/data`)**.

## How It Works

- When GCP preempts the Spot GPU VM (`instance_termination_action = "STOP"`), its boot disk, `3000 GB` Hyperdisk, and reserved static external IP (`dev-gpu-vm-ip`) stay attached (`TERMINATED` state).
- `gpu-watchdog.service` on the always-on `STANDARD` Controller VM checks `dev-gpu-vm` every `20s` and automatically runs `gcloud compute instances start --async` (retrying every `30s` on stockout until Spot capacity returns).
- The Controller VM uses a dedicated least-privilege service account (`dev-gpu-ctrl`) granted `roles/compute.instanceAdmin.v1` **only on the specific GPU VM instance**.
- Direct public internet ingress is **disabled** (`enable_public_ingress = false`); workstation and `setup.sh` access uses `gcloud compute ssh --tunnel-through-iap`.

## Usage

Provision the machine via [`../../scripts/deploy.sh`](../../scripts/deploy.sh) (uses your **logged-in `gcloud` credentials** and **active `gcloud` project**, defaulting to `europe-west4`), then configure the GitHub Actions runner via [`../../scripts/setup.sh`](../../scripts/setup.sh):

```bash
# Preview resolved credentials, project, and Terraform commands
./development/scripts/deploy.sh --provider=gcp --dry-run

# Provision in default region (europe-west4)
./development/scripts/deploy.sh --provider=gcp

# Cycle across all G4-capable regions until live Spot capacity is found
./development/scripts/deploy.sh --provider=gcp --cycle-regions

# Configure the persistent GitHub Actions runner on dev-gpu-controller
./development/scripts/setup.sh --provider=gcp --repo=vitorecomp/<repo> --token=<TOKEN>
```

## Watchdog & GPU SSH Commands on the Controller VM

The Controller VM comes pre-configured with passwordless SSH + `sudo` into the GPU VM (`10.10.0.11`) via `/etc/ssh/ssh_config.d/90-gpu.conf`:

```bash
ssh gpu                       # Open an interactive shell on the GPU VM (10.10.0.11)
gpu-ssh 'nvidia-smi'          # Run a command on the GPU VM (auto-installs ~/.ssh/gpu_ed25519 if needed)
gpu-wait-ssh 600              # Wait up to 600s for GPU VM SSH to come up (e.g. during Spot restart)
scp file.py gpu:/mnt/data/    # Copy files to/from the GPU VM

gpu-status                    # Show GPU VM state + watchdog service logs
gpu-pause                     # Pause auto-restart (creates /etc/gpu-watchdog.paused)
gpu-resume                    # Resume auto-restart (removes /etc/gpu-watchdog.paused)
```

## Connecting

```bash
# Connect to the Controller VM via gcloud IAP
eval "$(terraform output -raw controller_ssh_command)"

# Connect directly to the GPU VM via gcloud IAP
eval "$(terraform output -raw gpu_ssh_command)"
```
