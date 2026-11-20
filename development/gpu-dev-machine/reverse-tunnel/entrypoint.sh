#!/usr/bin/env bash
# Resilient reverse SSH tunnel (`autossh -M 0 -N -R ...`) forwarding an internal
# Podman network service (e.g. `litellm:4000` or `deepseek-harness:3080`) onto a
# remote machine.

set -euo pipefail

: "${TUNNEL_SSH_HOST:?Set TUNNEL_SSH_HOST in .env (target machine hostname or IP)}"
: "${TUNNEL_SSH_USER:?Set TUNNEL_SSH_USER in .env (SSH username on target machine)}"
: "${REMOTE_PORT:?Set REMOTE_PORT (port opened on target machine)}"
: "${TARGET_HOST:?Set TARGET_HOST (internal service hostname, e.g. litellm)}"
: "${TARGET_PORT:?Set TARGET_PORT (internal service port, e.g. 4000)}"

TUNNEL_SSH_PORT="${TUNNEL_SSH_PORT:-22}"
REMOTE_BIND_ADDRESS="${TUNNEL_BIND_ADDRESS:-127.0.0.1}"
STRICT_HOST_KEY_CHECKING="${TUNNEL_STRICT_HOST_KEY_CHECKING:-accept-new}"
MOUNTED_KEY="/run/tunnel/ssh_key"
MOUNTED_KNOWN_HOSTS="/run/tunnel/known_hosts"

if [[ ! -s "${MOUNTED_KEY}" ]]; then
  echo "[error] SSH private key not found or empty at ${MOUNTED_KEY} (check TUNNEL_SSH_KEY_FILE in .env)." >&2
  exit 1
fi

RUNTIME_SSH_DIR="/tmp/tunnel-ssh"
install -d -m 0700 "${RUNTIME_SSH_DIR}"
cp "${MOUNTED_KEY}" "${RUNTIME_SSH_DIR}/id_key"
chmod 0600 "${RUNTIME_SSH_DIR}/id_key"

KNOWN_HOSTS_TARGET="/data/known_hosts"
if [[ -s "${MOUNTED_KNOWN_HOSTS}" ]]; then
  cp "${MOUNTED_KNOWN_HOSTS}" "${RUNTIME_SSH_DIR}/known_hosts"
  chmod 0600 "${RUNTIME_SSH_DIR}/known_hosts"
  KNOWN_HOSTS_TARGET="${RUNTIME_SSH_DIR}/known_hosts"
  STRICT_HOST_KEY_CHECKING="yes"
else
  touch "${KNOWN_HOSTS_TARGET}"
  chmod 0600 "${KNOWN_HOSTS_TARGET}"
fi

FORWARD_SPEC="${REMOTE_BIND_ADDRESS}:${REMOTE_PORT}:${TARGET_HOST}:${TARGET_PORT}"
echo "[reverse-tunnel] Forwarding remote ${TUNNEL_SSH_USER}@${TUNNEL_SSH_HOST}:${TUNNEL_SSH_PORT} (${REMOTE_BIND_ADDRESS}:${REMOTE_PORT}) -> ${TARGET_HOST}:${TARGET_PORT}"

exec autossh -M 0 -N \
  -p "${TUNNEL_SSH_PORT}" \
  -i "${RUNTIME_SSH_DIR}/id_key" \
  -o "IdentitiesOnly=yes" \
  -o "BatchMode=yes" \
  -o "ExitOnForwardFailure=yes" \
  -o "ServerAliveInterval=15" \
  -o "ServerAliveCountMax=3" \
  -o "ConnectTimeout=10" \
  -o "TCPKeepAlive=yes" \
  -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}" \
  -o "UserKnownHostsFile=${KNOWN_HOSTS_TARGET}" \
  -R "${FORWARD_SPEC}" \
  "${TUNNEL_SSH_USER}@${TUNNEL_SSH_HOST}"
