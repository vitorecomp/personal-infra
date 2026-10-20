#!/usr/bin/env python3
"""Idempotently seeds the initial Ghost Admin Owner account and activates the custom theme via the Ghost Admin API.

Designed to run as a post-deploy step in the deployment pipeline (not on every
container startup).
1. Checks `GET /ghost/api/admin/authentication/setup/`:
   - If `setup[0].status` is `false`, sends `POST /ghost/api/admin/authentication/setup/`
     using `BLOG_ADMIN_EMAIL` and `BLOG_ADMIN_PASSWORD` from environment variables.
2. Logs into `POST /ghost/api/admin/session/` to obtain a session cookie and:
   - Activates the `vitorx86-garage` theme (`PUT /ghost/api/admin/themes/vitorx86-garage/activate/`).
   - Removes Ghost's default `"Coming soon"` post (`slug:coming-soon`) if present.
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

DEFAULT_BLOG_URL = "https://blog.vitorx86.dev"
DEFAULT_ADMIN_NAME = "Vitor Vieira"
DEFAULT_BLOG_TITLE = "vitorx86.dev // blog"
DEFAULT_THEME_NAME = "vitorx86-garage"
DEFAULT_FALLBACK_SNI = "vitorx86.dev"
SETUP_ENDPOINT = "/ghost/api/admin/authentication/setup/"
SESSION_ENDPOINT = "/ghost/api/admin/session/"


class _SNIOverrideHTTPSConnection(http.client.HTTPSConnection):
    """HTTPSConnection that allows overriding the TLS SNI hostname while preserving HTTP Host."""

    def __init__(self, host: str, port: int = 443, sni_hostname: str | None = None, timeout: float = 20.0) -> None:
        super().__init__(host, port=port, timeout=timeout)
        self._sni_hostname = sni_hostname or host

    def connect(self) -> None:
        sock = socket.create_connection((self.host, self.port), self.timeout)
        context = ssl.create_default_context()
        self.sock = context.wrap_socket(sock, server_hostname=self._sni_hostname)


def _request_ghost_api(
    blog_url: str,
    method: str,
    path: str,
    payload: dict[str, object] | None = None,
    cookie: str | None = None,
    fallback_sni: str = DEFAULT_FALLBACK_SNI,
    timeout: float = 20.0,
) -> tuple[int, dict[str, object], list[str]]:
    parsed = urlparse(blog_url)
    host = parsed.hostname or "blog.vitorx86.dev"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    origin = f"{parsed.scheme}://{host}"

    headers = {
        "Host": host,
        "Origin": origin,
        "Accept": "application/json",
        "User-Agent": "personal-infra-ghost-seeder/1.0",
    }
    if cookie:
        headers["Cookie"] = cookie
    serverless_token = os.environ.get("GHOST_SERVERLESS_ID_TOKEN", "").strip()
    if serverless_token:
        headers["X-Serverless-Authorization"] = f"Bearer {serverless_token}"
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
                conn = http.client.HTTPConnection(host=host, port=port, timeout=timeout)
            try:
                conn.request(method, path, body=body_bytes, headers=headers)
                resp = conn.getresponse()
                raw = resp.read().decode("utf-8", errors="replace")
                set_cookies = resp.headers.get_all("Set-Cookie") or []
                data = json.loads(raw) if raw.strip().startswith("{") else {"raw": raw}
                return resp.status, data, set_cookies
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
    raise RuntimeError("Failed to connect to Ghost Admin API")


def _extract_session_cookie(set_cookies: list[str]) -> str | None:
    parts: list[str] = []
    for header in set_cookies:
        first_pair = header.split(";", 1)[0].strip()
        if first_pair:
            parts.append(first_pair)
    return "; ".join(parts) if parts else None


def _reconcile_theme_and_posts(
    blog_url: str,
    email: str,
    password: str,
    theme_name: str = DEFAULT_THEME_NAME,
    fallback_sni: str = DEFAULT_FALLBACK_SNI,
) -> None:
    try:
        login_status, login_data, set_cookies = _request_ghost_api(
            blog_url=blog_url,
            method="POST",
            path=SESSION_ENDPOINT,
            payload={"username": email, "password": password},
            fallback_sni=fallback_sni,
        )
        if login_status not in (200, 201):
            print(
                f"[warn] Could not authenticate Ghost Admin session (HTTP {login_status}: {login_data}); "
                "relying on container pre-boot DB reconciler."
            )
            return

        cookie = _extract_session_cookie(set_cookies)
        if not cookie:
            print("[warn] Ghost Admin session did not return a Set-Cookie header.")
            return

        # 1. Activate custom theme
        theme_status, theme_data, _ = _request_ghost_api(
            blog_url=blog_url,
            method="PUT",
            path=f"/ghost/api/admin/themes/{theme_name}/activate/",
            payload={},
            cookie=cookie,
            fallback_sni=fallback_sni,
        )
        if theme_status == 200:
            print(f"[ok] Activated Ghost theme '{theme_name}'.")
        else:
            print(
                f"[warn] Could not activate theme '{theme_name}' via API (HTTP {theme_status}: {theme_data})."
            )

        # 2. Delete default "Coming soon" post if present
        posts_status, posts_data, _ = _request_ghost_api(
            blog_url=blog_url,
            method="GET",
            path="/ghost/api/admin/posts/?filter=slug:coming-soon",
            cookie=cookie,
            fallback_sni=fallback_sni,
        )
        if posts_status == 200 and isinstance(posts_data.get("posts"), list):
            for post in posts_data["posts"]:
                if isinstance(post, dict) and post.get("slug") == "coming-soon" and post.get("id"):
                    post_id = post["id"]
                    del_status, _, _ = _request_ghost_api(
                        blog_url=blog_url,
                        method="DELETE",
                        path=f"/ghost/api/admin/posts/{post_id}/",
                        cookie=cookie,
                        fallback_sni=fallback_sni,
                    )
                    if del_status in (200, 204):
                        print("[ok] Removed default 'Coming soon' post (0 articles).")
    except Exception as exc:
        print(f"[warn] Post-seed theme/post reconciliation warning: {exc}")


def seed_ghost_admin(
    blog_url: str,
    email: str,
    password: str,
    name: str = DEFAULT_ADMIN_NAME,
    blog_title: str = DEFAULT_BLOG_TITLE,
    theme_name: str = DEFAULT_THEME_NAME,
    fallback_sni: str = DEFAULT_FALLBACK_SNI,
    retries: int = 18,
    retry_delay: float = 5.0,
    dry_run: bool = False,
) -> int:
    if not email or not password:
        print(
            "[skip] BLOG_ADMIN_EMAIL or BLOG_ADMIN_PASSWORD is not set; skipping Ghost Admin seeding."
        )
        return 0

    if dry_run:
        print(
            f"[dry-run] Would check GET {blog_url.rstrip('/')}{SETUP_ENDPOINT}, "
            f"seed Ghost Owner '{email}' if needed, and activate theme '{theme_name}'."
        )
        return 0

    print(f"[seed] Checking Ghost Admin setup status at {blog_url.rstrip('/')}{SETUP_ENDPOINT} ...")
    setup_completed: bool | None = None
    saw_forbidden = False
    for attempt in range(1, retries + 1):
        try:
            status_code, data, _ = _request_ghost_api(
                blog_url=blog_url,
                method="GET",
                path=SETUP_ENDPOINT,
                fallback_sni=fallback_sni,
            )
            if status_code == 200 and isinstance(data.get("setup"), list):
                setup_list = data["setup"]
                if setup_list and isinstance(setup_list[0], dict):
                    setup_completed = bool(setup_list[0].get("status"))
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
                f"[wait] Attempt {attempt}/{retries}: Ghost API not ready yet ({exc}), retrying in {retry_delay}s..."
            )
        time.sleep(retry_delay)

    if setup_completed is None:
        if saw_forbidden:
            print(
                "[warn] Cloud Run service returned HTTP 403 Forbidden (public invoker IAM / --no-invoker-iam-check "
                "requires roles/run.admin on compute-bench). Skipping Ghost Admin seed until public invoker is enabled."
            )
            return 0
        print(
            f"[error] Timed out waiting for Ghost Admin API at {blog_url.rstrip('/')}{SETUP_ENDPOINT}",
            file=sys.stderr,
        )
        return 1

    if setup_completed:
        print("[ok] Ghost Admin Owner is already configured; reconciling active theme & initial posts...")
        _reconcile_theme_and_posts(
            blog_url=blog_url,
            email=email,
            password=password,
            theme_name=theme_name,
            fallback_sni=fallback_sni,
        )
        return 0

    print(f"[seed] Initial setup required. Creating Ghost Owner account for {email} ...")
    payload: dict[str, object] = {
        "setup": [
            {
                "name": name,
                "email": email,
                "password": password,
                "blogTitle": blog_title,
            }
        ]
    }

    try:
        post_status, post_data, _ = _request_ghost_api(
            blog_url=blog_url,
            method="POST",
            path=SETUP_ENDPOINT,
            payload=payload,
            fallback_sni=fallback_sni,
        )
    except Exception as exc:
        print(f"[error] Failed to POST Ghost Admin setup: {exc}", file=sys.stderr)
        return 1

    if post_status in (200, 201):
        print(f"[ok] Successfully seeded Ghost Admin Owner account ({email}).")
        _reconcile_theme_and_posts(
            blog_url=blog_url,
            email=email,
            password=password,
            theme_name=theme_name,
            fallback_sni=fallback_sni,
        )
        return 0

    print(
        f"[error] Ghost Admin setup failed with HTTP {post_status}: {post_data}",
        file=sys.stderr,
    )
    return 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Idempotently seed the initial Ghost Admin Owner account and activate the custom theme."
    )
    parser.add_argument(
        "--blog-url",
        type=str,
        default=os.environ.get("BLOG_URL", DEFAULT_BLOG_URL),
        help=f"Canonical Ghost URL (default: {DEFAULT_BLOG_URL})",
    )
    parser.add_argument(
        "--email",
        type=str,
        default=os.environ.get("BLOG_ADMIN_EMAIL", ""),
        help="Ghost Admin Owner email (defaults to $BLOG_ADMIN_EMAIL).",
    )
    parser.add_argument(
        "--name",
        type=str,
        default=os.environ.get("BLOG_ADMIN_NAME", DEFAULT_ADMIN_NAME),
        help=f"Ghost Admin Owner display name (default: {DEFAULT_ADMIN_NAME}).",
    )
    parser.add_argument(
        "--blog-title",
        type=str,
        default=os.environ.get("BLOG_TITLE", DEFAULT_BLOG_TITLE),
        help=f"Ghost publication title (default: {DEFAULT_BLOG_TITLE}).",
    )
    parser.add_argument(
        "--theme",
        type=str,
        default=os.environ.get("BLOG_THEME_NAME", DEFAULT_THEME_NAME),
        help=f"Ghost theme to activate (default: {DEFAULT_THEME_NAME}).",
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
        help="Preview the Ghost Admin setup check without making network calls.",
    )
    args = parser.parse_args()

    password = os.environ.get("BLOG_ADMIN_PASSWORD", "")
    sys.exit(
        seed_ghost_admin(
            blog_url=args.blog_url,
            email=args.email,
            password=password,
            name=args.name,
            blog_title=args.blog_title,
            theme_name=args.theme,
            fallback_sni=args.fallback_sni,
            retries=args.retries,
            retry_delay=args.retry_delay,
            dry_run=args.dry_run,
        )
    )


if __name__ == "__main__":
    main()
