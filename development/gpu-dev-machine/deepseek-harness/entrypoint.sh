#!/usr/bin/env bash
set -euo pipefail

export DSH_HOME="${DSH_HOME:-/dsh-home}"
export LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://litellm:4000/v1}"
export LITELLM_API_KEY="${LITELLM_API_KEY:-${LITELLM_MASTER_KEY:-}}"
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-$LITELLM_BASE_URL}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-$LITELLM_API_KEY}"

PROFILE_DIR="${DSH_HOME}/profiles/web"
mkdir -p "${PROFILE_DIR}"

# Seed / refresh the Cordis profile patch so DeepSeek Harness routes to the LiteLLM server.
sed "s|__LITELLM_BASE_URL__|${LITELLM_BASE_URL}|g" \
  /etc/deepseek-harness/cordis.patch.yml.template > "${PROFILE_DIR}/cordis.patch.yml"

# Register dsh-gateway-provider idempotently on the web profile if supported by this dsh build.
dsh plugin --profile web add dsh-gateway-provider >/dev/null 2>&1 || true

# `dsh web` intentionally binds only to loopback (127.0.0.1); expose 0.0.0.0:3080 inside the
# container namespace via socat while the host publishes strictly to 127.0.0.1:3080.
INTERNAL_PORT="${DSH_INTERNAL_PORT:-3081}"
PUBLIC_PORT="${DSH_PORT:-3080}"
socat "TCP-LISTEN:${PUBLIC_PORT},bind=0.0.0.0,fork,reuseaddr" "TCP:127.0.0.1:${INTERNAL_PORT}" &

exec dsh web --host 127.0.0.1 --port "${INTERNAL_PORT}"
