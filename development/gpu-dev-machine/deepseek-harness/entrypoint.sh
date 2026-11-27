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

# `dsh web` binds loopback only (127.0.0.1:3081). Caddy fronts it on 0.0.0.0:3080 inside the container namespace
# (the host publishes 127.0.0.1:3080, the reverse tunnel reaches deepseek-harness:3080) and proxies HTTP + WebSocket.
#
# Login: dsh mints a random launch token per process, accepted once on `GET /?token=...`, which sets a signed cookie
# valid for 30 days (its signing secret persists in $DSH_HOME/.credentials.yaml, so restarts keep sessions). With
# HARNESS_PASSWORD set, `/login` asks for that password (HTTP basic auth, user HARNESS_USER) and redirects to the
# current tokenized URL, so nobody has to read the token from this container's log.
INTERNAL_PORT="${DSH_INTERNAL_PORT:-3081}"
PUBLIC_PORT="${DSH_PORT:-3080}"
DSH_LOG="$(mktemp /tmp/dsh-web.XXXXXX.log)"

dsh web --host 127.0.0.1 --port "${INTERNAL_PORT}" --no-open > >(tee -a "${DSH_LOG}") 2>&1 &
DSH_PID=$!
CADDY_PID=""
trap 'kill -TERM "${DSH_PID}" ${CADDY_PID:+"${CADDY_PID}"} 2>/dev/null || true' TERM INT

token=""
for _ in $(seq 1 600); do
  token="$(sed 's/\x1b\[[0-9;]*m//g' "${DSH_LOG}" | grep -oE '[?&]token=[^&[:space:]]+' | tail -n1 | cut -d= -f2- || true)"
  [[ -n "${token}" ]] && break
  if ! kill -0 "${DSH_PID}" 2>/dev/null; then
    echo "[harness] dsh web exited before printing its URL." >&2
    wait "${DSH_PID}" || exit $?
    exit 1
  fi
  sleep 1
done
[[ -n "${token}" ]] || { echo "[harness] no launch token from dsh web after 10 min." >&2; exit 1; }

if [[ -n "${HARNESS_PASSWORD:-}" ]]; then
  # The password never appears in argv: caddy reads it (twice) from stdin.
  hash="$(printf '%s\n%s\n' "${HARNESS_PASSWORD}" "${HARNESS_PASSWORD}" | caddy hash-password 2>/dev/null | tail -n1)"
  [[ "${hash}" == \$2* ]] || { echo "[harness] could not hash HARNESS_PASSWORD." >&2; exit 1; }
  login_block="route /login {
		basic_auth {
			${HARNESS_USER:-admin} ${hash}
		}
		redir * /?token=${token} 302
	}"
  echo "[harness] /login enabled (basic auth user '${HARNESS_USER:-admin}')."
else
  login_block='respond /login "Set HARNESS_PASSWORD to enable /login." 404'
  echo "[harness] HARNESS_PASSWORD not set: /login disabled; log in with the 'dsh web:' URL above (port 3080)." >&2
fi

CADDYFILE="$(mktemp /tmp/Caddyfile.XXXXXX)"
cat > "${CADDYFILE}" <<EOF
{
	admin off
	auto_https off
	persist_config off
}
:${PUBLIC_PORT} {
	${login_block}
	reverse_proxy 127.0.0.1:${INTERNAL_PORT}
}
EOF
chmod 0600 "${CADDYFILE}"

caddy run --config "${CADDYFILE}" --adapter caddyfile &
CADDY_PID=$!

# Either process exiting ends the container; the restart policy brings both back (with a fresh launch token).
set +e
wait -n "${DSH_PID}" "${CADDY_PID}"
rc=$?
kill -TERM "${DSH_PID}" "${CADDY_PID}" 2>/dev/null
wait 2>/dev/null
exit "${rc}"
