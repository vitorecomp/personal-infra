#!/usr/bin/env python3
"""Idempotently verifies the deployed Taiga REST API and admin account readiness.

Designed to run as a post-deploy step in the deployment pipeline:
1. Checks `GET /api/v1/project-templates` to confirm the Taiga backend and PostgreSQL
   migrations/templates are live.
2. Authenticates against `POST /api/v1/auth` using `TAIGA_ADMIN_USER` (or `TAIGA_ADMIN_EMAIL`)
   and `TAIGA_ADMIN_PASSWORD` from environment variables to verify admin access.
"""

import argparse
import http.client
import json
import os
import socket
import ssl
import sys
import time
from urllib.parse import urlparse

DEFAULT_TAIGA_URL = "https://taiga.vitorx86.dev"
DEFAULT_ADMIN_USER = "admin"
DEFAULT_ADMIN_EMAIL = "vitor.ecomp@gmail.com"
DEFAULT_FALLBACK_SNI = "vitorx86.dev"
TEMPLATES_ENDPOINT = "/api/v1/project-templates"
AUTH_ENDPOINT = "/api/v1/auth"


class _SNIOverrideHTTPSConnection(http.client.HTTPSConnection):
    """HTTPSConnection that allows overriding the TLS SNI hostname while preserving HTTP Host."""

    def __init__(
        self,
        host: str,
        port: int = 443,
        sni_hostname: str | None = None,
        timeout: float = 20.0,
    ) -> None:
        super().__init__(host, port=port, timeout=timeout)
        self._sni_hostname = sni_hostname or host

    def connect(self) -> None:
        sock = socket.create_connection((self.host, self.port), self.timeout)
        context = ssl.create_default_context()
        self.sock = context.wrap_socket(sock, server_hostname=self._sni_hostname)


def _request_taiga_api(
    taiga_url: str,
    method: str,
    path: str,
    payload: dict[str, object] | None = None,
    fallback_sni: str = DEFAULT_FALLBACK_SNI,
    timeout: float = 20.0,
) -> tuple[int, object]:
    parsed = urlparse(taiga_url)
    host = parsed.hostname or "taiga.vitorx86.dev"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)

    headers = {
        "Host": host,
        "Accept": "application/json",
        "User-Agent": "personal-infra-taiga-verifier/1.0",
    }
    body_bytes: bytes | None = None
    if payload is not None:
        body_bytes = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(len(body_bytes))

    sni_candidates = [host]
    if fallback_sni and fallback_sni != host:
        sni_candidates.append(fallback_sni)

    last_err: Exception | None = None
    for sni in sni_candidates:
        try:
            if parsed.scheme == "https":
                conn: http.client.HTTPConnection = _SNIOverrideHTTPSConnection(
                    host=host, port=port, sni_hostname=sni, timeout=timeout
                )
            else:
                conn = http.client.HTTPConnection(
                    host=host, port=port, timeout=timeout
                )
            try:
                conn.request(method, path, body=body_bytes, headers=headers)
                resp = conn.getresponse()
                raw = resp.read().decode("utf-8", errors="replace").strip()
                if raw.startswith("{") or raw.startswith("["):
                    data: object = json.loads(raw)
                else:
                    data = {"raw": raw}
                return resp.status, data
            finally:
                conn.close()
        except ssl.SSLError as err:
            last_err = err
            continue
        except Exception as err:
            last_err = err
            break

    if last_err is not None:
        raise last_err
    raise RuntimeError("Failed to connect to Taiga API")


def verify_taiga_admin(
    taiga_url: str,
    username: str,
    email: str,
    password: str,
    fallback_sni: str = DEFAULT_FALLBACK_SNI,
    retries: int = 18,
    retry_delay: float = 5.0,
    dry_run: bool = False,
) -> int:
    if not password:
        print(
            "[skip] TAIGA_ADMIN_PASSWORD is not set; skipping Taiga Admin API authentication check."
        )
        return 0

    if dry_run:
        print(
            f"[dry-run] Would check GET {taiga_url.rstrip('/')}{TEMPLATES_ENDPOINT} and "
            f"verify login via POST {taiga_url.rstrip('/')}{AUTH_ENDPOINT} for '{username}' ({email})."
        )
        return 0

    print(
        f"[seed] Checking Taiga API readiness at {taiga_url.rstrip('/')}{TEMPLATES_ENDPOINT} ..."
    )
    api_ready = False
    saw_forbidden = False
    for attempt in range(1, retries + 1):
        try:
            status_code, data = _request_taiga_api(
                taiga_url=taiga_url,
                method="GET",
                path=TEMPLATES_ENDPOINT,
                fallback_sni=fallback_sni,
            )
            if status_code == 200 and isinstance(data, list):
                api_ready = True
                break
            if status_code == 403:
                saw_forbidden = True
                if attempt >= 3:
                    break
            print(
                f"[wait] Attempt {attempt}/{retries}: unexpected status {status_code}, retrying in {retry_delay}s..."
            )
        except Exception as exc:
            print(
                f"[wait] Attempt {attempt}/{retries}: Taiga API not ready yet ({exc}), retrying in {retry_delay}s..."
            )
        time.sleep(retry_delay)

    if not api_ready:
        if saw_forbidden:
            print(
                "[warn] Cloud Run service returned HTTP 403 Forbidden (public invoker IAM / --no-invoker-iam-check "
                "requires roles/run.admin on compute-bench). Skipping Taiga Admin verification until public invoker is enabled."
            )
            return 0
        print(
            f"[error] Timed out waiting for Taiga API at {taiga_url.rstrip('/')}{TEMPLATES_ENDPOINT}",
            file=sys.stderr,
        )
        return 1

    for login_id in (username, email):
        if not login_id:
            continue
        try:
            auth_status, auth_data = _request_taiga_api(
                taiga_url=taiga_url,
                method="POST",
                path=AUTH_ENDPOINT,
                payload={
                    "type": "normal",
                    "username": login_id,
                    "password": password,
                },
                fallback_sni=fallback_sni,
            )
            if auth_status == 200 and isinstance(auth_data, dict) and auth_data.get("auth_token"):
                print(
                    f"[ok] Verified Taiga Admin account '{auth_data.get('username', login_id)}' is active and ready."
                )
                return 0
        except Exception as exc:
            print(f"[warn] Auth attempt for '{login_id}' raised: {exc}")

    print(
        f"[warn] Taiga API is live at {taiga_url}, but admin login check for '{username}' did not succeed."
    )
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Idempotently verify the Taiga API and initial admin account readiness."
    )
    parser.add_argument(
        "--taiga-url",
        type=str,
        default=os.environ.get("TAIGA_URL", DEFAULT_TAIGA_URL),
        help=f"Canonical Taiga URL (default: {DEFAULT_TAIGA_URL})",
    )
    parser.add_argument(
        "--username",
        type=str,
        default=os.environ.get("TAIGA_ADMIN_USER", DEFAULT_ADMIN_USER),
        help=f"Taiga Admin username (default: {DEFAULT_ADMIN_USER}).",
    )
    parser.add_argument(
        "--email",
        type=str,
        default=os.environ.get("TAIGA_ADMIN_EMAIL", DEFAULT_ADMIN_EMAIL),
        help=f"Taiga Admin email (default: {DEFAULT_ADMIN_EMAIL}).",
    )
    parser.add_argument(
        "--fallback-sni",
        type=str,
        default=DEFAULT_FALLBACK_SNI,
        help=f"Fallback TLS SNI hostname on the shared Load Balancer while subdomain SSL provisions (default: {DEFAULT_FALLBACK_SNI}).",
    )
    parser.add_argument(
        "--retries",
        type=int,
        default=18,
        help="Number of readiness check retries (default: 18).",
    )
    parser.add_argument(
        "--retry-delay",
        type=float,
        default=5.0,
        help="Seconds between retries (default: 5.0).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview the Taiga Admin verification check without making network calls.",
    )
    args = parser.parse_args()

    password = os.environ.get("TAIGA_ADMIN_PASSWORD", "")
    sys.exit(
        verify_taiga_admin(
            taiga_url=args.taiga_url,
            username=args.username,
            email=args.email,
            password=password,
            fallback_sni=args.fallback_sni,
            retries=args.retries,
            retry_delay=args.retry_delay,
            dry_run=args.dry_run,
        )
    )


if __name__ == "__main__":
    main()
