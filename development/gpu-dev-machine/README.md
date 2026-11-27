# `development/gpu-dev-machine` — Podman & `podman-compose` Inference + Agent Stack

Container definitions and **`podman-compose`** orchestration deployed onto `dev-gpu-vm` (`g4-standard-192`: 4× NVIDIA RTX PRO 6000 = `384 GiB` VRAM, `720 GiB` CPU RAM, `3 TB` `/mnt/data` Hyperdisk).

---

## Stack Architecture

```mermaid
flowchart LR
  B["Target Bastion / Remote Machine"] <-- "autossh -R :3080" --- HT["deepseek-harness-tunnel"]
  B <-- "autossh -R :4000" --- LT["litellm-tunnel"]
  HT --> H["deepseek-harness (:3080)"]
  LT --> L["litellm (:4000)"]
  H -- "OpenAI API (http://litellm:4000/v1)" --> L
  L -- "OpenAI API (http://vllm-server:8000/v1)" --> R["vllm-server (:8000)"]
  R --- M[("/mnt/data/huggingface: DeepSeek-V4.1-Flash (475 GiB Full + CPU Offload)")]
```

| Service | Directory | Base / Pinned Packages | Role |
| :--- | :--- | :--- | :--- |
| **`vllm-server`** | *(no build: image only)* | `vllm/vllm-openai:v0.34.0` (`vllm serve`; ≥ 0.34 needed on SM120 GPUs) | Serves the **full unquantized** `deepseek-ai/DeepSeek-V4.1-Flash` (552B MoE, `475 GiB`) across 4 GPUs (`--tensor-parallel-size=4`) with **CPU offload** (`--cpu-offload-gb=48` + `--engram-config` `cpu_offload`), `fp8` KV cache and the `deepseek_v41` tokenizer / tool / reasoning parsers. No Ray: DeepSeek-V4.1-Flash needs vLLM ≥ 0.30 and Ray Serve LLM (≤ 2.60.1) pins vLLM 0.29. |
| **`litellm`** | [`litellm/`](./litellm) | `python:3.12-slim-bookworm` + `litellm[proxy]==1.109.1` | OpenAI-compatible AI gateway routing `deepseek-v4.1-flash` to `http://vllm-server:8000/v1`. |
| **`deepseek-harness`** | [`deepseek-harness/`](./deepseek-harness) | `node:22-bookworm-slim` + `@deepseek-ai/dsh@0.2.2-rc.1` + `dsh-gateway-provider@1.1.5` + Caddy 2.11.9 | DeepSeek Harness (`dsh web` on 127.0.0.1:3081) behind a Caddy front on `:3080` (HTTP + WebSocket) whose `/login` takes `HARNESS_PASSWORD` and redirects to dsh's current launch-token URL; talks to `http://litellm:4000/v1`. |
| **`litellm-tunnel`** | [`reverse-tunnel/`](./reverse-tunnel) | `debian:bookworm-slim` + `autossh` + `openssh-client` | Persistent reverse SSH tunnel forwarding `REMOTE_LITELLM_PORT` (`4000`) on `TUNNEL_SSH_HOST` back to `litellm:4000`. |
| **`deepseek-harness-tunnel`** | [`reverse-tunnel/`](./reverse-tunnel) | `debian:bookworm-slim` + `autossh` + `openssh-client` | Persistent reverse SSH tunnel forwarding `REMOTE_HARNESS_PORT` (`3080`) on `TUNNEL_SSH_HOST` back to `deepseek-harness:3080`. |

---

## 1. One-Time GPU VM Host Setup (Podman + NVIDIA CDI + `/mnt/data` Storage)

Because `dev-gpu-vm` has a `10 GB` boot disk and a **`3000 GB` `/mnt/data` Hyperdisk**, configure Podman's image store (`graphroot`) and Hugging Face cache on `/mnt/data` so container images and the `475 GiB` model checkpoint live on the persistent volume:

```bash
# 1. Install NVIDIA driver (if not yet installed), Podman, podman-compose, and NVIDIA Container Toolkit
sudo apt-get update
sudo apt-get install -y ubuntu-drivers-common podman podman-compose uidmap slirp4netns fuse-overlayfs curl gpg
sudo ubuntu-drivers install   # reboot once if kernel modules were newly installed

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

# 2. Generate NVIDIA CDI spec for Podman (`nvidia.com/gpu=all`)
sudo mkdir -p /etc/cdi
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# 3. Point Podman storage + temp dir to /mnt/data (avoids filling the 10 GB root disk)
sudo mkdir -p /mnt/data/containers/storage /mnt/data/containers/tmp \
              /mnt/data/huggingface \
              /mnt/data/deepseek-harness/dsh-home \
              /mnt/data/deepseek-harness/workspace \
              /mnt/data/reverse-tunnel/state/litellm \
              /mnt/data/reverse-tunnel/state/harness
sudo chmod -R 1777 /mnt/data/deepseek-harness /mnt/data/reverse-tunnel/state
sudo touch /mnt/data/reverse-tunnel/known_hosts

# 4. Generate a dedicated SSH keypair for the reverse SSH tunnels and authorize `.pub` on your target machine
sudo ssh-keygen -t ed25519 -N "" -C "gpu-dev-reverse-tunnel" -f /mnt/data/reverse-tunnel/id_ed25519
sudo chmod 0644 /mnt/data/reverse-tunnel/id_ed25519.pub
cat /mnt/data/reverse-tunnel/id_ed25519.pub   # add to ~/.ssh/authorized_keys on TUNNEL_SSH_HOST

sudo mkdir -p /etc/containers
cat <<'EOF' | sudo tee /etc/containers/storage.conf >/dev/null
[storage]
driver = "overlay"
graphroot = "/mnt/data/containers/storage"
runroot = "/run/containers/storage"
EOF
export TMPDIR=/mnt/data/containers/tmp
```

---

## 2. Build & Launch with Podman + `podman-compose`

```bash
cd development/gpu-dev-machine

# Create .env, set LITELLM_MASTER_KEY, and set TUNNEL_SSH_HOST / TUNNEL_SSH_USER for the reverse SSH tunnels
cp .env.example .env
chmod 600 .env
sed -i "s|changeme-litellm-master-key|sk-$(openssl rand -hex 24)|" .env

# Build images with Podman and start all 5 containers via podman-compose
sudo TMPDIR=/mnt/data/containers/tmp podman-compose -f compose.yml up -d --build

# Follow logs (model load, Web UI login URL, and reverse tunnels)
sudo podman logs -f vllm-server
sudo podman logs -f deepseek-harness
sudo podman logs -f litellm-tunnel
sudo podman logs -f deepseek-harness-tunnel
```

> **Remote `sshd` Note:** By default (`TUNNEL_BIND_ADDRESS=127.0.0.1`), `litellm-tunnel` and `deepseek-harness-tunnel` bind `127.0.0.1:4000` and `127.0.0.1:3080` on `TUNNEL_SSH_HOST` (works with default `sshd_config`). If you set `TUNNEL_BIND_ADDRESS=0.0.0.0` to expose them on a LAN/interface, set `GatewayPorts clientspecified` and `ClientAliveInterval 15` in `/etc/ssh/sshd_config` on the remote machine.

---

## 3. Access Web UI & Endpoints Over `gcloud` IAP Tunnel

All ports bind strictly to `127.0.0.1` on `dev-gpu-vm`. Forward them securely to your workstation with `gcloud compute ssh --tunnel-through-iap`:

```bash
gcloud compute ssh dev-gpu-vm \
  --zone=europe-west4-b \
  --project=<gcp-project-id> \
  --tunnel-through-iap \
  -- -L 3080:127.0.0.1:3080 -L 4000:127.0.0.1:4000 -L 8000:127.0.0.1:8000
```

- **DeepSeek Harness UI**: `http://127.0.0.1:3080`
- **LiteLLM Proxy API**: `http://127.0.0.1:4000/v1`
- **vLLM OpenAI API (direct, no auth)**: `http://127.0.0.1:8000/v1`

### Quick Smoke Test Against LiteLLM

```bash
source .env
curl -sS http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4.1-flash",
    "messages": [{"role": "user", "content": "Reply with OK if DeepSeek V4.1 Flash is online."}]
  }'
```
