#!/usr/bin/env python3
"""Enrolls GitHub repositories from workspace/documentation/repo_stats.csv as projects on Taiga.

Behavior:
1. Reads `workspace/documentation/repo_stats.csv`.
2. Filters repositories by:
   - Assigned `folder` (by default only repos with a non-empty `folder`, or a specific
     folder when passed via positional `folder` / `--folder`, unless `--include-unassigned` is set).
   - Fork status (skips forks by default unless `--include-forks` is set).
   - Optional `--repo` filter for specific repository names.
3. Optionally enriches project descriptions and tags from the GitHub API
   (using `GITHUB_TOKEN` or `METRICS_TOKEN` when available, with graceful fallback).
4. Authenticates against the Taiga REST API (`/api/v1/auth`), checks existing projects
   (`/api/v1/projects`) for idempotency, and creates any missing projects (`/api/v1/projects`)
   with the selected template (`kanban` or `scrum`) and visibility (`private` by default).
"""

import argparse
import csv
import http.client
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

USER = "vitorecomp"
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CSV_PATH = REPO_ROOT / "documentation" / "repo_stats.csv"
DEFAULT_TAIGA_URL = "https://taiga.vitorx86.dev"
DEFAULT_ADMIN_USER = "admin"
DEFAULT_ADMIN_EMAIL = "vitor.ecomp@gmail.com"
DEFAULT_FALLBACK_SNI = "vitorx86.dev"
DEFAULT_TEMPLATE = "kanban"


class _SNIOverrideHTTPSConnection(http.client.HTTPSConnection):
    """HTTPSConnection that allows overriding the TLS SNI hostname while preserving HTTP Host."""

    def __init__(
        self,
        host: str,
        port: int = 443,
        sni_hostname: str | None = None,
        timeout: float = 25.0,
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
    auth_token: str | None = None,
    fallback_sni: str = DEFAULT_FALLBACK_SNI,
    timeout: float = 25.0,
) -> tuple[int, object]:
    parsed = urllib.parse.urlparse(taiga_url)
    host = parsed.hostname or "taiga.vitorx86.dev"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)

    headers: dict[str, str] = {
        "Host": host,
        "Accept": "application/json",
        "User-Agent": "personal-infra-taiga-project-enroller/1.0",
        "x-disable-pagination": "True",
    }
    if auth_token:
        headers["Authorization"] = f"Bearer {auth_token}"

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


def slugify_name(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or name.lower()


def load_candidate_repos(
    csv_path: Path,
    folder_filter: str | None = None,
    include_unassigned: bool = False,
    include_forks: bool = False,
    repo_names: set[str] | None = None,
) -> list[dict[str, str]]:
    if not csv_path.exists():
        sys.exit(f"[error] CSV file not found: {csv_path}")

    candidates: list[dict[str, str]] = []
    with csv_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            name = (row.get("name") or "").strip()
            if not name:
                continue

            if repo_names and name not in repo_names:
                continue

            folder = (row.get("folder") or "").strip()
            is_fork = (row.get("is a fork") or "").strip().lower() == "true"

            if not repo_names:
                if folder_filter and folder != folder_filter:
                    continue
                if not folder_filter and not include_unassigned and not folder:
                    continue
                if is_fork and not include_forks:
                    continue

            candidates.append(
                {
                    "name": name,
                    "link": (row.get("link") or "").strip(),
                    "ssh_link": (row.get("ssh link") or "").strip(),
                    "last_updated": (row.get("last updated") or "").strip(),
                    "is_fork": str(is_fork),
                    "folder": folder,
                    "is_custom": (row.get("is-custom") or "").strip(),
                    "is_template": (row.get("is-template") or "").strip(),
                }
            )

    return candidates


def fetch_github_descriptions(user: str, token: str | None) -> dict[str, dict[str, object]]:
    """Fetches optional GitHub repository descriptions and topics, falling back gracefully on error."""
    metadata: dict[str, dict[str, object]] = {}
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "personal-infra-taiga-project-enroller/1.0",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    page = 1
    use_authenticated = bool(token)
    while True:
        if use_authenticated:
            params = urllib.parse.urlencode(
                {"per_page": 100, "affiliation": "owner", "page": page}
            )
            url = f"https://api.github.com/user/repos?{params}"
        else:
            params = urllib.parse.urlencode(
                {"per_page": 100, "type": "owner", "page": page}
            )
            url = f"https://api.github.com/users/{user}/repos?{params}"

        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as resp:
                batch = json.load(resp)
        except urllib.error.HTTPError as err:
            if use_authenticated and err.code in (401, 403):
                use_authenticated = False
                continue
            break
        except Exception:
            break

        if not isinstance(batch, list) or not batch:
            break

        for item in batch:
            if not isinstance(item, dict) or not item.get("name"):
                continue
            repo_name = str(item["name"])
            desc = str(item.get("description") or "").strip()
            topics = item.get("topics") if isinstance(item.get("topics"), list) else []
            language = str(item.get("language") or "").strip()
            metadata[repo_name] = {
                "description": desc,
                "topics": [str(t) for t in topics if t],
                "language": language,
            }

        if len(batch) < 100:
            break
        page += 1

    return metadata


def build_project_payload(
    repo: dict[str, str],
    gh_meta: dict[str, object] | None,
    template_id: int | None,
    template_slug: str,
    is_private: bool,
) -> dict[str, object]:
    folder = repo.get("folder") or "unassigned"
    link = repo.get("link") or f"https://github.com/{USER}/{repo['name']}"
    gh_desc = str((gh_meta or {}).get("description") or "").strip()

    if gh_desc:
        description = f"{gh_desc}\n\nGitHub: {link} (workspace/{folder})"
    else:
        description = f"GitHub repository {link} (workspace/{folder})"

    tags: list[str] = []
    if repo.get("folder"):
        tags.append(repo["folder"].lower())
    if repo.get("is_fork") == "True":
        tags.append("fork")
    if repo.get("is_template", "").lower() == "true":
        tags.append("template")
    if gh_meta:
        lang = str(gh_meta.get("language") or "").strip().lower()
        if lang and lang not in tags:
            tags.append(lang)
        for topic in gh_meta.get("topics", []):  # type: ignore[union-attr]
            topic_str = str(topic).strip().lower()
            if topic_str and topic_str not in tags:
                tags.append(topic_str)

    use_kanban = template_slug.lower() == "kanban"
    use_scrum = template_slug.lower() == "scrum"

    payload: dict[str, object] = {
        "name": repo["name"],
        "description": description,
        "is_private": is_private,
        "is_backlog_activated": use_scrum,
        "is_kanban_activated": use_kanban or not use_scrum,
        "is_wiki_activated": True,
        "is_issues_activated": True,
        "tags": tags[:10],
    }
    if template_id is not None:
        payload["creation_template"] = template_id
    return payload


def _resolve_password_from_cloud_run(
    project_id: str = "compute-bench",
    region: str = "us-central1",
    service_name: str = "taiga",
) -> str:
    """Falls back to reading TAIGA_ADMIN_PASSWORD from the Cloud Run service via gcloud if authenticated locally."""
    try:
        res = subprocess.run(
            [
                "gcloud",
                "run",
                "services",
                "describe",
                service_name,
                f"--project={project_id}",
                f"--region={region}",
                "--format=json",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if res.returncode != 0:
            return ""
        data = json.loads(res.stdout)
        containers = (
            data.get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("containers", [])
        )
        if not containers:
            return ""
        for env_entry in containers[0].get("env", []):
            if isinstance(env_entry, dict) and env_entry.get("name") == "TAIGA_ADMIN_PASSWORD":
                return str(env_entry.get("value") or "").strip()
    except Exception:
        return ""
    return ""


def authenticate_taiga(
    taiga_url: str,
    username: str,
    email: str,
    password: str,
    auth_token: str,
    fallback_sni: str,
) -> str:
    if auth_token:
        return auth_token

    if not password:
        password = _resolve_password_from_cloud_run()

    if not password:
        sys.exit(
            "[error] Set TAIGA_ADMIN_PASSWORD (or TAIGA_AUTH_TOKEN) in your environment to enroll projects on Taiga."
        )

    for login_id in (username, email):
        if not login_id:
            continue
        status_code, data = _request_taiga_api(
            taiga_url=taiga_url,
            method="POST",
            path="/api/v1/auth",
            payload={
                "type": "normal",
                "username": login_id,
                "password": password,
            },
            fallback_sni=fallback_sni,
        )
        if status_code == 200 and isinstance(data, dict) and data.get("auth_token"):
            return str(data["auth_token"])

    sys.exit(
        f"[error] Failed to authenticate against {taiga_url.rstrip('/')}/api/v1/auth for '{username}' / '{email}'."
    )


def resolve_template_id(
    taiga_url: str,
    auth_token: str,
    template_slug: str,
    fallback_sni: str,
) -> int | None:
    try:
        status_code, data = _request_taiga_api(
            taiga_url=taiga_url,
            method="GET",
            path="/api/v1/project-templates",
            auth_token=auth_token,
            fallback_sni=fallback_sni,
        )
        if status_code == 200 and isinstance(data, list):
            for item in data:
                if isinstance(item, dict) and str(item.get("slug", "")).lower() == template_slug.lower():
                    if isinstance(item.get("id"), int):
                        return int(item["id"])
            for item in data:
                if isinstance(item, dict) and isinstance(item.get("id"), int):
                    return int(item["id"])
    except Exception as exc:
        print(f"[warn] Could not query project templates ({exc}); using default flags.")
    return None


def fetch_existing_projects(
    taiga_url: str,
    auth_token: str,
    fallback_sni: str,
) -> dict[str, dict[str, object]]:
    status_code, data = _request_taiga_api(
        taiga_url=taiga_url,
        method="GET",
        path="/api/v1/projects",
        auth_token=auth_token,
        fallback_sni=fallback_sni,
    )
    if status_code != 200 or not isinstance(data, list):
        sys.exit(
            f"[error] Failed to list existing Taiga projects (HTTP {status_code}: {data})"
        )

    by_key: dict[str, dict[str, object]] = {}
    for proj in data:
        if not isinstance(proj, dict):
            continue
        name = str(proj.get("name") or "").strip()
        slug = str(proj.get("slug") or "").strip().lower()
        if name:
            by_key[name.lower()] = proj
            by_key[slugify_name(name)] = proj
        if slug:
            by_key[slug] = proj
            # Taiga often prefixes slugs with `<owner>-<project-slug>`
            if "-" in slug:
                by_key[slug.split("-", 1)[1]] = proj
    return by_key


def enroll_projects(
    csv_path: Path,
    taiga_url: str,
    username: str,
    email: str,
    password: str,
    auth_token: str,
    folder_filter: str | None = None,
    include_unassigned: bool = False,
    include_forks: bool = False,
    repo_names: set[str] | None = None,
    template_slug: str = DEFAULT_TEMPLATE,
    is_private: bool = True,
    fetch_descriptions: bool = True,
    update_existing: bool = False,
    fallback_sni: str = DEFAULT_FALLBACK_SNI,
    dry_run: bool = False,
) -> int:
    candidates = load_candidate_repos(
        csv_path=csv_path,
        folder_filter=folder_filter,
        include_unassigned=include_unassigned,
        include_forks=include_forks,
        repo_names=repo_names,
    )

    if not candidates:
        print("[ok] No matching repositories found in repo_stats.csv to enroll.")
        return 0

    gh_token = os.environ.get("GITHUB_TOKEN") or os.environ.get("METRICS_TOKEN")
    gh_metadata: dict[str, dict[str, object]] = {}
    if fetch_descriptions and not dry_run:
        gh_metadata = fetch_github_descriptions(USER, gh_token)

    visibility_label = "private" if is_private else "public"
    if dry_run:
        print(
            f"[dry-run] Would enroll {len(candidates)} repositories from {csv_path} "
            f"onto {taiga_url} (template={template_slug}, visibility={visibility_label}):"
        )
        for repo in candidates:
            folder_tag = repo["folder"] or "unassigned"
            print(
                f"  - {repo['name']} (folder={folder_tag}, url={repo['link']})"
            )
        return 0

    token = authenticate_taiga(
        taiga_url=taiga_url,
        username=username,
        email=email,
        password=password,
        auth_token=auth_token,
        fallback_sni=fallback_sni,
    )
    template_id = resolve_template_id(
        taiga_url=taiga_url,
        auth_token=token,
        template_slug=template_slug,
        fallback_sni=fallback_sni,
    )
    existing_projects = fetch_existing_projects(
        taiga_url=taiga_url,
        auth_token=token,
        fallback_sni=fallback_sni,
    )

    created_count = 0
    updated_count = 0
    skipped_count = 0
    failed_count = 0

    for repo in candidates:
        name = repo["name"]
        lookup_keys = (name.lower(), slugify_name(name))
        existing = next(
            (existing_projects[k] for k in lookup_keys if k in existing_projects),
            None,
        )
        payload = build_project_payload(
            repo=repo,
            gh_meta=gh_metadata.get(name),
            template_id=template_id,
            template_slug=template_slug,
            is_private=is_private,
        )

        if existing is not None:
            if not update_existing:
                print(
                    f"[skip] Project '{name}' already exists on Taiga (slug={existing.get('slug')})"
                )
                skipped_count += 1
                continue

            project_id = existing.get("id")
            patch_payload = {
                "name": payload["name"],
                "description": payload["description"],
                "is_private": payload["is_private"],
                "tags": payload["tags"],
            }
            status_code, resp_data = _request_taiga_api(
                taiga_url=taiga_url,
                method="PATCH",
                path=f"/api/v1/projects/{project_id}",
                payload=patch_payload,
                auth_token=token,
                fallback_sni=fallback_sni,
            )
            if status_code == 200:
                print(f"[update] Updated existing Taiga project '{name}'")
                updated_count += 1
            else:
                print(
                    f"[error] Failed to update '{name}' (HTTP {status_code}: {resp_data})",
                    file=sys.stderr,
                )
                failed_count += 1
            continue

        status_code, resp_data = _request_taiga_api(
            taiga_url=taiga_url,
            method="POST",
            path="/api/v1/projects",
            payload=payload,
            auth_token=token,
            fallback_sni=fallback_sni,
        )
        if status_code in (200, 201) and isinstance(resp_data, dict):
            slug = resp_data.get("slug", name)
            print(
                f"[create] Created Taiga project '{name}' -> {taiga_url.rstrip('/')}/project/{slug}/"
            )
            created_count += 1
        else:
            print(
                f"[error] Failed to create Taiga project '{name}' (HTTP {status_code}: {resp_data})",
                file=sys.stderr,
            )
            failed_count += 1

    print(
        f"\nSummary: candidates={len(candidates)}, created={created_count}, "
        f"updated={updated_count}, skipped={skipped_count}, failed={failed_count}"
    )
    return 1 if failed_count > 0 else 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Idempotently enroll GitHub repositories from repo_stats.csv as projects on the Taiga server."
    )
    parser.add_argument(
        "folder",
        nargs="?",
        default=None,
        help="Optional workspace category folder filter (e.g., 'personal', 'work', 'opensource', 'portifolio').",
    )
    parser.add_argument(
        "--folder",
        dest="folder_flag",
        type=str,
        default=None,
        help="Filter repositories by a specific folder column value in repo_stats.csv.",
    )
    parser.add_argument(
        "--repo",
        dest="repos",
        action="append",
        default=[],
        help="Enroll specific repository name(s) (can be specified multiple times).",
    )
    parser.add_argument(
        "--include-unassigned",
        action="store_true",
        help="Also enroll repositories that do not have a folder assigned in repo_stats.csv.",
    )
    parser.add_argument(
        "--include-forks",
        action="store_true",
        help="Also enroll forked repositories (skipped by default).",
    )
    parser.add_argument(
        "--template",
        choices=["kanban", "scrum"],
        default=DEFAULT_TEMPLATE,
        help=f"Taiga project methodology template to use (default: {DEFAULT_TEMPLATE}).",
    )
    parser.add_argument(
        "--public",
        action="store_true",
        help="Create Taiga projects as public instead of private (default: private).",
    )
    parser.add_argument(
        "--update-existing",
        action="store_true",
        help="Update descriptions, tags, and visibility on projects that already exist in Taiga.",
    )
    parser.add_argument(
        "--no-github-meta",
        action="store_true",
        help="Skip fetching live repository descriptions and topics from the GitHub API.",
    )
    parser.add_argument(
        "--csv",
        type=Path,
        default=DEFAULT_CSV_PATH,
        help=f"Path to repo_stats.csv (default: {DEFAULT_CSV_PATH}).",
    )
    parser.add_argument(
        "--taiga-url",
        type=str,
        default=os.environ.get("TAIGA_URL", DEFAULT_TAIGA_URL),
        help=f"Base URL of the Taiga server (default: {DEFAULT_TAIGA_URL}).",
    )
    parser.add_argument(
        "--username",
        type=str,
        default=os.environ.get("TAIGA_ADMIN_USER", DEFAULT_ADMIN_USER),
        help=f"Taiga username (default: {DEFAULT_ADMIN_USER}).",
    )
    parser.add_argument(
        "--email",
        type=str,
        default=os.environ.get("TAIGA_ADMIN_EMAIL", DEFAULT_ADMIN_EMAIL),
        help=f"Taiga admin email fallback (default: {DEFAULT_ADMIN_EMAIL}).",
    )
    parser.add_argument(
        "--fallback-sni",
        type=str,
        default=DEFAULT_FALLBACK_SNI,
        help=f"Fallback TLS SNI hostname while subdomain SSL provisions (default: {DEFAULT_FALLBACK_SNI}).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview which repositories would be enrolled as Taiga projects without making network calls.",
    )
    args = parser.parse_args()

    folder_filter = args.folder_flag or args.folder
    repo_names = {r.strip() for r in args.repos if r.strip()} or None
    password = os.environ.get("TAIGA_ADMIN_PASSWORD", "")
    auth_token = os.environ.get("TAIGA_AUTH_TOKEN", "")

    sys.exit(
        enroll_projects(
            csv_path=args.csv.expanduser().resolve(),
            taiga_url=args.taiga_url,
            username=args.username,
            email=args.email,
            password=password,
            auth_token=auth_token,
            folder_filter=folder_filter,
            include_unassigned=args.include_unassigned,
            include_forks=args.include_forks,
            repo_names=repo_names,
            template_slug=args.template,
            is_private=not args.public,
            fetch_descriptions=not args.no_github_meta,
            update_existing=args.update_existing,
            fallback_sni=args.fallback_sni,
            dry_run=args.dry_run,
        )
    )


if __name__ == "__main__":
    main()
