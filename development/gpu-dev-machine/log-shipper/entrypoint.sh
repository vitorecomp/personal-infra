#!/usr/bin/env bash
# Streams this GPU VM's journal (startup script, boot hook, runner, every container, kernel) to the log host over SSH.
# The log host's restricted user (cloud/scripts/bootstrap_vm.py --tunnel-pubkey-file: same key as the reverse tunnels)
# can only append the stream to /var/log/gpu-dev/<LOG_STREAM>.log there, which logrotate caps.
# A cursor in /data resumes after a reconnect or a container restart; secrets that may appear in logs are redacted.

set -euo pipefail

: "${LOG_SSH_HOST:?Set LOG_SSH_HOST (log host; deploy_gpu_stack.sh defaults it to TUNNEL_SSH_HOST)}"
LOG_SSH_PORT="${LOG_SSH_PORT:-22}"
LOG_SSH_USER="${LOG_SSH_USER:-gpulog}"
LOG_STREAM="${LOG_STREAM:-gpu-vm}"
MOUNTED_KEY="/run/ship/ssh_key"
MOUNTED_KNOWN_HOSTS="/run/ship/known_hosts"
CURSOR_FILE="/data/journal.cursor"

JOURNAL_DIR="/host/journal/$(cat /etc/machine-id)"
if [[ ! -d "${JOURNAL_DIR}" ]]; then
  echo "[log-shipper] No persistent journal at ${JOURNAL_DIR}." >&2
  exit 1
fi
if [[ ! -s "${MOUNTED_KEY}" ]]; then
  echo "[log-shipper] SSH private key not found or empty at ${MOUNTED_KEY}." >&2
  exit 1
fi

SSH_DIR="$(mktemp -d)"
install -m 0600 "${MOUNTED_KEY}" "${SSH_DIR}/id_key"
STRICT="accept-new"
KNOWN_HOSTS="/data/known_hosts"
if [[ -s "${MOUNTED_KNOWN_HOSTS}" ]]; then
  install -m 0600 "${MOUNTED_KNOWN_HOSTS}" "${SSH_DIR}/known_hosts"
  KNOWN_HOSTS="${SSH_DIR}/known_hosts"
  STRICT="yes"
fi

# Launch tokens (harness URLs), bearer tokens, LiteLLM/OpenAI-style keys and Hugging Face tokens never leave the VM.
redact() {
  sed -u -E \
    -e 's/([?&]token=)[^&[:space:]"]+/\1<redacted>/g' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1<redacted>/g' \
    -e 's/sk-[A-Za-z0-9_-]{16,}/sk-<redacted>/g' \
    -e 's/hf_[A-Za-z0-9]{20,}/hf_<redacted>/g'
}

# Healthcheck chatter, ~70% of the raw journal: podman's "healthy" results, the health-probe GETs, and the AppArmor
# ptrace denials pgrep-based healthchecks trigger. Unhealthy/starting results, container starts and deaths are kept.
drop_noise() {
  grep --line-buffered -vE \
    -e 'container health_status .*health_status=healthy' \
    -e '"GET /health(/liveliness|/readiness)? HTTP/1\.[01]" 200' \
    -e 'apparmor="DENIED" operation="ptrace" .*comm="pgrep"' \
    -e 'kauditd_printk_skb: [0-9]+ callbacks suppressed'
}

# journalctl saves its cursor when it exits cleanly (SIGTERM), so stop it that way: on container stop (bash as PID 1
# ignores SIGTERM unless trapped) and as soon as ssh drops (otherwise it only notices at its next write).
stop_journalctl() { pkill -TERM -x journalctl 2>/dev/null || true; wait 2>/dev/null || true; }
trap 'stop_journalctl; exit 0' TERM INT

while true; do
  if [[ -s "${CURSOR_FILE}" ]]; then
    start=(--cursor-file="${CURSOR_FILE}")
  else
    start=(--cursor-file="${CURSOR_FILE}" --boot)
  fi
  echo "[log-shipper] Streaming the journal to ${LOG_SSH_USER}@${LOG_SSH_HOST}:${LOG_SSH_PORT} as '${LOG_STREAM}'..."
  set +e
  journalctl -D "${JOURNAL_DIR}" "${start[@]}" --follow --output=short-iso --no-pager --quiet \
    | drop_noise \
    | redact \
    | ssh -p "${LOG_SSH_PORT}" -i "${SSH_DIR}/id_key" \
        -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        -o "StrictHostKeyChecking=${STRICT}" -o "UserKnownHostsFile=${KNOWN_HOSTS}" \
        "${LOG_SSH_USER}@${LOG_SSH_HOST}" "${LOG_STREAM}" &
  wait $!
  rc=$?
  stop_journalctl
  set -e
  echo "[log-shipper] The connection to the log host ended (exit ${rc}); retrying in 30 s."
  sleep 30 &
  wait $!
done
