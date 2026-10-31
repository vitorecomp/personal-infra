#!/usr/bin/env python3
"""Full-featured CLI for managing Taiga projects, sprints, user stories, tasks, issues, epics, and wiki pages.

Designed for both interactive use and AI agent automation via the `taiga` skill.
Uses only the Python 3.10+ standard library and supports `--dry-run` on all mutating commands.
"""

import argparse
import http.client
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
from typing import Any
import urllib.parse

DEFAULT_TAIGA_URL = "https://taiga.vitorx86.dev"
DEFAULT_ADMIN_USER = "admin"
DEFAULT_ADMIN_EMAIL = "vitor.ecomp@gmail.com"
DEFAULT_FALLBACK_SNI = "vitorx86.dev"
TOKEN_CACHE_PATH = Path.home() / ".cache" / "taiga_cli" / "token.json"


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


def slugify_name(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or name.lower()


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
            if (
                isinstance(env_entry, dict)
                and env_entry.get("name") == "TAIGA_ADMIN_PASSWORD"
            ):
                return str(env_entry.get("value") or "").strip()
    except Exception:
        return ""
    return ""


def _load_cached_token(taiga_url: str, username: str) -> tuple[str, int | None]:
    try:
        if not TOKEN_CACHE_PATH.exists():
            return "", None
        data = json.loads(TOKEN_CACHE_PATH.read_text(encoding="utf-8"))
        key = f"{taiga_url.rstrip('/')}|{username}"
        entry = data.get(key)
        if isinstance(entry, dict) and entry.get("auth_token"):
            user_id = entry.get("user_id")
            return str(entry["auth_token"]), (
                int(user_id) if isinstance(user_id, int) else None
            )
    except Exception:
        pass
    return "", None


def _save_cached_token(
    taiga_url: str, username: str, auth_token: str, user_id: int | None
) -> None:
    try:
        TOKEN_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        data: dict[str, Any] = {}
        if TOKEN_CACHE_PATH.exists():
            try:
                data = json.loads(TOKEN_CACHE_PATH.read_text(encoding="utf-8"))
            except Exception:
                data = {}
        key = f"{taiga_url.rstrip('/')}|{username}"
        data[key] = {"auth_token": auth_token, "user_id": user_id}
        TOKEN_CACHE_PATH.write_text(json.dumps(data, indent=2), encoding="utf-8")
        os.chmod(TOKEN_CACHE_PATH, 0o600)
    except Exception:
        pass


class TaigaClient:
    """Zero-dependency REST API client for Taiga (`/api/v1`)."""

    def __init__(
        self,
        taiga_url: str = DEFAULT_TAIGA_URL,
        username: str = DEFAULT_ADMIN_USER,
        email: str = DEFAULT_ADMIN_EMAIL,
        password: str = "",
        auth_token: str = "",
        fallback_sni: str = DEFAULT_FALLBACK_SNI,
    ) -> None:
        self.taiga_url = taiga_url.rstrip("/")
        self.username = username
        self.email = email
        self.password = password
        self.auth_token = auth_token
        self.fallback_sni = fallback_sni
        self.user_id: int | None = None

    def _raw_request(
        self,
        method: str,
        path: str,
        payload: object = None,
        token: str | None = None,
        disable_pagination: bool = True,
        timeout: float = 25.0,
    ) -> tuple[int, Any]:
        parsed = urllib.parse.urlparse(self.taiga_url)
        host = parsed.hostname or "taiga.vitorx86.dev"
        port = parsed.port or (443 if parsed.scheme == "https" else 80)

        headers: dict[str, str] = {
            "Host": host,
            "Accept": "application/json",
            "User-Agent": "personal-infra-taiga-cli/1.0",
        }
        if disable_pagination:
            headers["x-disable-pagination"] = "True"
        if token:
            headers["Authorization"] = f"Bearer {token}"

        body_bytes: bytes | None = None
        if payload is not None:
            body_bytes = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
            headers["Content-Length"] = str(len(body_bytes))

        sni_candidates = [host]
        if self.fallback_sni and self.fallback_sni != host:
            sni_candidates.append(self.fallback_sni)

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
                        data: Any = json.loads(raw)
                    elif not raw:
                        data = {}
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

    def authenticate(self, force_refresh: bool = False) -> str:
        if self.auth_token and not force_refresh:
            return self.auth_token

        if not force_refresh:
            cached_tok, cached_uid = _load_cached_token(self.taiga_url, self.username)
            if cached_tok:
                self.auth_token = cached_tok
                self.user_id = cached_uid
                return self.auth_token

        password = self.password or _resolve_password_from_cloud_run()
        if not password:
            sys.exit(
                "[error] Set TAIGA_ADMIN_PASSWORD or TAIGA_AUTH_TOKEN (or authenticate gcloud to compute-bench)."
            )

        for login_id in (self.username, self.email):
            if not login_id:
                continue
            status, data = self._raw_request(
                "POST",
                "/api/v1/auth",
                payload={
                    "type": "normal",
                    "username": login_id,
                    "password": password,
                },
                token=None,
            )
            if status == 200 and isinstance(data, dict) and data.get("auth_token"):
                self.auth_token = str(data["auth_token"])
                uid = data.get("id")
                self.user_id = int(uid) if isinstance(uid, int) else None
                _save_cached_token(
                    self.taiga_url, self.username, self.auth_token, self.user_id
                )
                return self.auth_token

        sys.exit(
            f"[error] Authentication failed against {self.taiga_url}/api/v1/auth for '{self.username}'."
        )

    def request(
        self,
        method: str,
        path: str,
        payload: object = None,
        disable_pagination: bool = True,
    ) -> tuple[int, Any]:
        token = self.authenticate(force_refresh=False)
        status, data = self._raw_request(
            method, path, payload=payload, token=token, disable_pagination=disable_pagination
        )
        if status == 401:
            token = self.authenticate(force_refresh=True)
            status, data = self._raw_request(
                method,
                path,
                payload=payload,
                token=token,
                disable_pagination=disable_pagination,
            )
        return status, data

    def get_current_user_id(self) -> int:
        if self.user_id is not None:
            return self.user_id
        status, data = self.request("GET", "/api/v1/users/me")
        if status == 200 and isinstance(data, dict) and isinstance(data.get("id"), int):
            self.user_id = int(data["id"])
            return self.user_id
        return 1

    def resolve_project(self, identifier: str) -> dict[str, Any]:
        """Resolves a project by numeric ID, slug, or case-insensitive name and returns its full detail object."""
        ident = identifier.strip()
        if ident.isdigit():
            status, data = self.request("GET", f"/api/v1/projects/{ident}")
            if status == 200 and isinstance(data, dict):
                return data

        for candidate_slug in (ident.lower(), slugify_name(ident)):
            encoded = urllib.parse.quote(candidate_slug)
            status, data = self.request(
                "GET", f"/api/v1/projects/by_slug?slug={encoded}"
            )
            if status == 200 and isinstance(data, dict):
                return data

        status, projects = self.request("GET", "/api/v1/projects")
        if status == 200 and isinstance(projects, list):
            for proj in projects:
                if not isinstance(proj, dict):
                    continue
                name = str(proj.get("name") or "").strip().lower()
                slug = str(proj.get("slug") or "").strip().lower()
                if ident.lower() in (name, slug) or slugify_name(ident) in (name, slug):
                    proj_id = proj.get("id")
                    detail_status, detail = self.request(
                        "GET", f"/api/v1/projects/{proj_id}"
                    )
                    if detail_status == 200 and isinstance(detail, dict):
                        return detail
                    return proj

        sys.exit(f"[error] Project '{identifier}' not found on {self.taiga_url}.")


def _find_named_id(
    items: list[dict[str, Any]] | Any, target_name: str
) -> int | None:
    if not isinstance(items, list) or not target_name:
        return None
    target_lower = target_name.strip().lower()
    if target_lower.isdigit():
        target_int = int(target_lower)
        for item in items:
            if isinstance(item, dict) and item.get("id") == target_int:
                return target_int
    for item in items:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or "").strip().lower()
        slug = str(item.get("slug") or "").strip().lower()
        if target_lower in (name, slug):
            if isinstance(item.get("id"), int):
                return int(item["id"])
    return None


def _parse_tags(raw_tags: str | None) -> list[str] | None:
    if raw_tags is None:
        return None
    if not raw_tags.strip():
        return []
    return [t.strip().lower() for t in raw_tags.split(",") if t.strip()]


def _resolve_sprint_id(
    client: TaigaClient, project_id: int, sprint_ident: str | None
) -> int | None:
    if not sprint_ident:
        return None
    ident = sprint_ident.strip()
    if ident.lower() in ("none", "null", "backlog"):
        return None
    if ident.isdigit():
        return int(ident)
    status, milestones = client.request(
        "GET", f"/api/v1/milestones?project={project_id}"
    )
    if status == 200 and isinstance(milestones, list):
        for m in milestones:
            if not isinstance(m, dict):
                continue
            name = str(m.get("name") or "").strip().lower()
            slug = str(m.get("slug") or "").strip().lower()
            if ident.lower() in (name, slug) and isinstance(m.get("id"), int):
                return int(m["id"])
    sys.exit(f"[error] Sprint/milestone '{sprint_ident}' not found in project {project_id}.")


def _print_output(data: Any, as_json: bool = False) -> None:
    if as_json:
        print(json.dumps(data, indent=2))
        return
    if isinstance(data, dict):
        for k, v in data.items():
            print(f"{k}: {v}")
    elif isinstance(data, list):
        for row in data:
            print(row)
    else:
        print(data)


# ---------------------------------------------------------------------------
# Subcommand Handlers
# ---------------------------------------------------------------------------


def handle_projects(client: TaigaClient, args: argparse.Namespace) -> int:
    action = args.projects_action
    if action == "list":
        path = "/api/v1/projects"
        if args.member_only:
            uid = client.get_current_user_id()
            path = f"/api/v1/projects?member={uid}&order_by=user_order"
        status, data = client.request("GET", path)
        if status != 200 or not isinstance(data, list):
            sys.exit(f"[error] Failed to list projects (HTTP {status}: {data})")
        if args.search:
            q = args.search.lower()
            data = [
                p
                for p in data
                if isinstance(p, dict)
                and (
                    q in str(p.get("name", "")).lower()
                    or q in str(p.get("slug", "")).lower()
                    or q in str(p.get("description", "")).lower()
                )
            ]
        if args.json:
            _print_output(data, as_json=True)
            return 0
        print(f"Projects ({len(data)}):")
        for idx, p in enumerate(data, start=1):
            if not isinstance(p, dict):
                continue
            mode = "scrum" if p.get("is_backlog_activated") else "kanban"
            vis = "private" if p.get("is_private") else "public"
            print(
                f"  {idx:2d}. [{p.get('id')}] {p.get('name')} (slug={p.get('slug')}, mode={mode}, {vis})"
            )
        return 0

    if action == "get":
        proj = client.resolve_project(args.project)
        if args.json:
            _print_output(proj, as_json=True)
            return 0
        mode = "scrum" if proj.get("is_backlog_activated") else "kanban"
        vis = "private" if proj.get("is_private") else "public"
        us_statuses = [s.get("name") for s in proj.get("us_statuses", []) if isinstance(s, dict)]
        task_statuses = [s.get("name") for s in proj.get("task_statuses", []) if isinstance(s, dict)]
        issue_statuses = [s.get("name") for s in proj.get("issue_statuses", []) if isinstance(s, dict)]
        points = [p.get("name") for p in proj.get("points", []) if isinstance(p, dict)]
        print(f"Project [{proj.get('id')}] {proj.get('name')} (slug={proj.get('slug')})")
        print(f"  URL:            {client.taiga_url}/project/{proj.get('slug')}/")
        print(f"  Methodology:    {mode} (backlog={proj.get('is_backlog_activated')}, kanban={proj.get('is_kanban_activated')})")
        print(f"  Visibility:     {vis}")
        print(f"  Description:    {proj.get('description')}")
        print(f"  Tags:           {proj.get('tags')}")
        print(f"  Story Statuses: {', '.join(str(x) for x in us_statuses)}")
        print(f"  Task Statuses:  {', '.join(str(x) for x in task_statuses)}")
        print(f"  Issue Statuses: {', '.join(str(x) for x in issue_statuses)}")
        print(f"  Story Points:   {', '.join(str(x) for x in points)}")
        return 0

    if action == "create":
        use_scrum = args.template == "scrum"
        payload: dict[str, Any] = {
            "name": args.name,
            "description": args.description or f"Project {args.name}",
            "is_private": not args.public,
            "is_backlog_activated": use_scrum,
            "is_kanban_activated": not use_scrum,
            "is_wiki_activated": True,
            "is_issues_activated": True,
            "creation_template": 1 if use_scrum else 2,
        }
        tags = _parse_tags(args.tags)
        if tags is not None:
            payload["tags"] = tags
        if args.dry_run:
            print(f"[dry-run] Would POST /api/v1/projects with payload: {json.dumps(payload)}")
            return 0
        status, data = client.request("POST", "/api/v1/projects", payload=payload)
        if status not in (200, 201) or not isinstance(data, dict):
            sys.exit(f"[error] Failed to create project (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
        else:
            print(
                f"[ok] Created project [{data.get('id')}] '{data.get('name')}' -> {client.taiga_url}/project/{data.get('slug')}/"
            )
        return 0

    if action == "update":
        proj = client.resolve_project(args.project)
        proj_id = proj["id"]
        payload = {}
        if args.name:
            payload["name"] = args.name
        if args.description is not None:
            payload["description"] = args.description
        if args.template:
            use_scrum = args.template == "scrum"
            payload["is_backlog_activated"] = use_scrum
            payload["is_kanban_activated"] = not use_scrum
        if args.public:
            payload["is_private"] = False
        elif args.private:
            payload["is_private"] = True
        tags = _parse_tags(args.tags)
        if tags is not None:
            payload["tags"] = tags
        if args.dry_run:
            print(
                f"[dry-run] Would PATCH /api/v1/projects/{proj_id} with payload: {json.dumps(payload)}"
            )
            return 0
        status, data = client.request("PATCH", f"/api/v1/projects/{proj_id}", payload=payload)
        if status != 200:
            sys.exit(f"[error] Failed to update project (HTTP {status}: {data})")
        print(f"[ok] Updated project [{proj_id}] '{proj.get('name')}'")
        return 0

    if action == "delete":
        proj = client.resolve_project(args.project)
        proj_id = proj["id"]
        if args.dry_run:
            print(f"[dry-run] Would DELETE /api/v1/projects/{proj_id} ('{proj.get('name')}')")
            return 0
        status, data = client.request("DELETE", f"/api/v1/projects/{proj_id}")
        if status not in (200, 204):
            sys.exit(f"[error] Failed to delete project (HTTP {status}: {data})")
        print(f"[ok] Deleted project [{proj_id}] '{proj.get('name')}'")
        return 0

    return 1


def handle_sprints(client: TaigaClient, args: argparse.Namespace) -> int:
    action = args.sprints_action
    if action == "list":
        proj = client.resolve_project(args.project)
        proj_id = proj["id"]
        path = f"/api/v1/milestones?project={proj_id}"
        if args.closed:
            path += "&closed=true"
        elif args.open:
            path += "&closed=false"
        status, data = client.request("GET", path)
        if status != 200 or not isinstance(data, list):
            sys.exit(f"[error] Failed to list sprints (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
            return 0
        print(f"Sprints in '{proj.get('name')}' ({len(data)}):")
        for m in data:
            if not isinstance(m, dict):
                continue
            state = "closed" if m.get("closed") else "open"
            print(
                f"  - [{m.get('id')}] {m.get('name')} ({m.get('estimated_start')} -> {m.get('estimated_finish')}, {state}, points={m.get('total_points')})"
            )
        return 0

    if action == "get":
        status, data = client.request("GET", f"/api/v1/milestones/{args.sprint_id}")
        if status != 200 or not isinstance(data, dict):
            sys.exit(f"[error] Sprint {args.sprint_id} not found (HTTP {status}: {data})")
        _print_output(data, as_json=args.json)
        return 0

    if action == "create":
        proj = client.resolve_project(args.project)
        payload = {
            "project": proj["id"],
            "name": args.name,
            "estimated_start": args.start,
            "estimated_finish": args.end,
        }
        if args.dry_run:
            print(f"[dry-run] Would POST /api/v1/milestones with payload: {json.dumps(payload)}")
            return 0
        status, data = client.request("POST", "/api/v1/milestones", payload=payload)
        if status not in (200, 201) or not isinstance(data, dict):
            sys.exit(f"[error] Failed to create sprint (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
        else:
            print(
                f"[ok] Created sprint [{data.get('id')}] '{data.get('name')}' ({data.get('estimated_start')} -> {data.get('estimated_finish')})"
            )
        return 0

    if action == "update":
        payload_upd: dict[str, Any] = {}
        if args.name:
            payload_upd["name"] = args.name
        if args.start:
            payload_upd["estimated_start"] = args.start
        if args.end:
            payload_upd["estimated_finish"] = args.end
        if args.closed:
            payload_upd["closed"] = True
        elif args.open:
            payload_upd["closed"] = False
        if args.dry_run:
            print(
                f"[dry-run] Would PATCH /api/v1/milestones/{args.sprint_id} with payload: {json.dumps(payload_upd)}"
            )
            return 0
        status, data = client.request(
            "PATCH", f"/api/v1/milestones/{args.sprint_id}", payload=payload_upd
        )
        if status != 200:
            sys.exit(f"[error] Failed to update sprint (HTTP {status}: {data})")
        print(f"[ok] Updated sprint [{args.sprint_id}]")
        return 0

    if action == "delete":
        if args.dry_run:
            print(f"[dry-run] Would DELETE /api/v1/milestones/{args.sprint_id}")
            return 0
        status, data = client.request("DELETE", f"/api/v1/milestones/{args.sprint_id}")
        if status not in (200, 204):
            sys.exit(f"[error] Failed to delete sprint (HTTP {status}: {data})")
        print(f"[ok] Deleted sprint [{args.sprint_id}]")
        return 0

    return 1


def handle_stories(client: TaigaClient, args: argparse.Namespace) -> int:
    action = args.stories_action
    if action == "list":
        proj = client.resolve_project(args.project)
        proj_id = proj["id"]
        params = [f"project={proj_id}"]
        if args.sprint:
            if args.sprint.lower() in ("backlog", "null", "none"):
                params.append("milestone__isnull=true")
            else:
                sid = _resolve_sprint_id(client, proj_id, args.sprint)
                if sid is not None:
                    params.append(f"milestone={sid}")
        if args.status:
            st_id = _find_named_id(proj.get("us_statuses"), args.status)
            if st_id is not None:
                params.append(f"status={st_id}")
        path = "/api/v1/userstories?" + "&".join(params)
        status, data = client.request("GET", path)
        if status != 200 or not isinstance(data, list):
            sys.exit(f"[error] Failed to list user stories (HTTP {status}: {data})")
        if args.tag:
            tag_q = args.tag.lower()
            data = [
                s
                for s in data
                if isinstance(s, dict)
                and any(
                    (isinstance(t, list) and t and str(t[0]).lower() == tag_q)
                    or (isinstance(t, str) and t.lower() == tag_q)
                    for t in (s.get("tags") or [])
                )
            ]
        if args.json:
            _print_output(data, as_json=True)
            return 0
        print(f"User Stories in '{proj.get('name')}' ({len(data)}):")
        for s in data:
            if not isinstance(s, dict):
                continue
            st_extra = s.get("status_extra_info") or {}
            st_name = st_extra.get("name") if isinstance(st_extra, dict) else s.get("status")
            pts = s.get("total_points")
            sprint = s.get("milestone_name") or (
                f"sprint:{s.get('milestone')}" if s.get("milestone") else "Backlog"
            )
            print(
                f"  - id={s.get('id')} (#{s.get('ref')}) [{st_name}] {s.get('subject')} (sprint={sprint}, points={pts})"
            )
        return 0

    if action == "get":
        if args.by_ref:
            if not args.project:
                sys.exit("[error] --project is required when using --by-ref.")
            proj = client.resolve_project(args.project)
            path = f"/api/v1/userstories/by_ref?project={proj['id']}&ref={args.story_id}"
        else:
            path = f"/api/v1/userstories/{args.story_id}"
        status, data = client.request("GET", path)
        if status != 200 or not isinstance(data, dict):
            sys.exit(f"[error] User story not found (HTTP {status}: {data})")
        _print_output(data, as_json=args.json)
        return 0

    if action == "create":
        proj = client.resolve_project(args.project)
        proj_id = proj["id"]
        payload: dict[str, Any] = {
            "project": proj_id,
            "subject": args.subject,
        }
        if args.description:
            payload["description"] = args.description
        if args.status:
            st_id = _find_named_id(proj.get("us_statuses"), args.status)
            if st_id is None:
                sys.exit(f"[error] Unknown user story status '{args.status}'.")
            payload["status"] = st_id
        if args.sprint:
            payload["milestone"] = _resolve_sprint_id(client, proj_id, args.sprint)
        if args.points:
            pt_id = _find_named_id(proj.get("points"), args.points)
            if pt_id is None:
                sys.exit(f"[error] Unknown story points value '{args.points}'.")
            roles = [
                r for r in (proj.get("roles") or []) if isinstance(r, dict) and r.get("computable")
            ]
            if roles:
                payload["points"] = {str(roles[0]["id"]): pt_id}
        tags = _parse_tags(args.tags)
        if tags is not None:
            payload["tags"] = tags
        if args.assign_to_me:
            payload["assigned_to"] = client.get_current_user_id()
        if args.dry_run:
            print(f"[dry-run] Would POST /api/v1/userstories with payload: {json.dumps(payload)}")
            return 0
        status, data = client.request("POST", "/api/v1/userstories", payload=payload)
        if status not in (200, 201) or not isinstance(data, dict):
            sys.exit(f"[error] Failed to create user story (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
        else:
            print(
                f"[ok] Created user story id={data.get('id')} (#{data.get('ref')}) '{data.get('subject')}'"
            )
        return 0

    if action == "bulk-create":
        proj = client.resolve_project(args.project)
        proj_id = proj["id"]
        payload_bulk: dict[str, Any] = {
            "project_id": proj_id,
            "bulk_stories": "\n".join(s.strip() for s in args.subjects if s.strip()),
        }
        if args.sprint:
            payload_bulk["milestone_id"] = _resolve_sprint_id(client, proj_id, args.sprint)
        if args.status:
            st_id = _find_named_id(proj.get("us_statuses"), args.status)
            if st_id is not None:
                payload_bulk["status_id"] = st_id
        if args.dry_run:
            print(
                f"[dry-run] Would POST /api/v1/userstories/bulk_create with payload: {json.dumps(payload_bulk)}"
            )
            return 0
        status, data = client.request(
            "POST", "/api/v1/userstories/bulk_create", payload=payload_bulk
        )
        if status not in (200, 201) or not isinstance(data, list):
            sys.exit(f"[error] Failed to bulk-create user stories (HTTP {status}: {data})")
        print(f"[ok] Bulk-created {len(data)} user stories in '{proj.get('name')}'")
        return 0

    if action == "update":
        cur_status, cur_story = client.request("GET", f"/api/v1/userstories/{args.story_id}")
        if cur_status != 200 or not isinstance(cur_story, dict):
            sys.exit(f"[error] User story {args.story_id} not found (HTTP {cur_status}: {cur_story})")
        proj = client.resolve_project(str(cur_story["project"]))
        payload_upd: dict[str, Any] = {"version": cur_story["version"]}
        if args.subject:
            payload_upd["subject"] = args.subject
        if args.description is not None:
            payload_upd["description"] = args.description
        if args.status:
            st_id = _find_named_id(proj.get("us_statuses"), args.status)
            if st_id is None:
                sys.exit(f"[error] Unknown user story status '{args.status}'.")
            payload_upd["status"] = st_id
        if args.sprint is not None:
            payload_upd["milestone"] = _resolve_sprint_id(client, proj["id"], args.sprint)
        if args.points:
            pt_id = _find_named_id(proj.get("points"), args.points)
            if pt_id is None:
                sys.exit(f"[error] Unknown story points value '{args.points}'.")
            null_pt_id = _find_named_id(proj.get("points"), "?")
            existing_pts = dict(cur_story.get("points") or {})
            for idx, role_id in enumerate(existing_pts):
                existing_pts[role_id] = pt_id if idx == 0 else (null_pt_id or existing_pts[role_id])
            payload_upd["points"] = existing_pts
        tags = _parse_tags(args.tags)
        if tags is not None:
            payload_upd["tags"] = tags
        if args.blocked_note is not None:
            payload_upd["is_blocked"] = True
            payload_upd["blocked_note"] = args.blocked_note
        elif args.unblock:
            payload_upd["is_blocked"] = False
            payload_upd["blocked_note"] = ""
        if args.dry_run:
            print(
                f"[dry-run] Would PATCH /api/v1/userstories/{args.story_id} with payload: {json.dumps(payload_upd)}"
            )
            return 0
        status, data = client.request(
            "PATCH", f"/api/v1/userstories/{args.story_id}", payload=payload_upd
        )
        if status != 200:
            sys.exit(f"[error] Failed to update user story (HTTP {status}: {data})")
        print(f"[ok] Updated user story id={args.story_id}")
        return 0

    if action == "delete":
        if args.dry_run:
            print(f"[dry-run] Would DELETE /api/v1/userstories/{args.story_id}")
            return 0
        status, data = client.request("DELETE", f"/api/v1/userstories/{args.story_id}")
        if status not in (200, 204):
            sys.exit(f"[error] Failed to delete user story (HTTP {status}: {data})")
        print(f"[ok] Deleted user story id={args.story_id}")
        return 0

    return 1


def handle_tasks(client: TaigaClient, args: argparse.Namespace) -> int:
    action = args.tasks_action
    if action == "list":
        proj = client.resolve_project(args.project)
        proj_id = proj["id"]
        params = [f"project={proj_id}"]
        if args.story:
            params.append(f"user_story={args.story}")
        if args.sprint:
            sid = _resolve_sprint_id(client, proj_id, args.sprint)
            if sid is not None:
                params.append(f"milestone={sid}")
        if args.status:
            st_id = _find_named_id(proj.get("task_statuses"), args.status)
            if st_id is not None:
                params.append(f"status={st_id}")
        status, data = client.request("GET", "/api/v1/tasks?" + "&".join(params))
        if status != 200 or not isinstance(data, list):
            sys.exit(f"[error] Failed to list tasks (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
            return 0
        print(f"Tasks in '{proj.get('name')}' ({len(data)}):")
        for t in data:
            if not isinstance(t, dict):
                continue
            st_extra = t.get("status_extra_info") or {}
            st_name = st_extra.get("name") if isinstance(st_extra, dict) else t.get("status")
            print(
                f"  - id={t.get('id')} (#{t.get('ref')}) [{st_name}] {t.get('subject')} (story={t.get('user_story')})"
            )
        return 0

    if action == "get":
        status, data = client.request("GET", f"/api/v1/tasks/{args.task_id}")
        if status != 200 or not isinstance(data, dict):
            sys.exit(f"[error] Task {args.task_id} not found (HTTP {status}: {data})")
        _print_output(data, as_json=args.json)
        return 0

    if action == "create":
        proj = client.resolve_project(args.project)
        proj_id = proj["id"]
        payload: dict[str, Any] = {
            "project": proj_id,
            "subject": args.subject,
        }
        if args.description:
            payload["description"] = args.description
        if args.story:
            payload["user_story"] = int(args.story)
        if args.sprint:
            payload["milestone"] = _resolve_sprint_id(client, proj_id, args.sprint)
        if args.status:
            st_id = _find_named_id(proj.get("task_statuses"), args.status)
            if st_id is None:
                sys.exit(f"[error] Unknown task status '{args.status}'.")
            payload["status"] = st_id
        tags = _parse_tags(args.tags)
        if tags is not None:
            payload["tags"] = tags
        if args.assign_to_me:
            payload["assigned_to"] = client.get_current_user_id()
        if args.dry_run:
            print(f"[dry-run] Would POST /api/v1/tasks with payload: {json.dumps(payload)}")
            return 0
        status, data = client.request("POST", "/api/v1/tasks", payload=payload)
        if status not in (200, 201) or not isinstance(data, dict):
            sys.exit(f"[error] Failed to create task (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
        else:
            print(
                f"[ok] Created task id={data.get('id')} (#{data.get('ref')}) '{data.get('subject')}'"
            )
        return 0

    if action == "update":
        cur_status, cur_task = client.request("GET", f"/api/v1/tasks/{args.task_id}")
        if cur_status != 200 or not isinstance(cur_task, dict):
            sys.exit(f"[error] Task {args.task_id} not found (HTTP {cur_status}: {cur_task})")
        proj = client.resolve_project(str(cur_task["project"]))
        payload_upd: dict[str, Any] = {"version": cur_task["version"]}
        if args.subject:
            payload_upd["subject"] = args.subject
        if args.description is not None:
            payload_upd["description"] = args.description
        if args.story is not None:
            payload_upd["user_story"] = int(args.story) if args.story.isdigit() else None
        if args.status:
            st_id = _find_named_id(proj.get("task_statuses"), args.status)
            if st_id is None:
                sys.exit(f"[error] Unknown task status '{args.status}'.")
            payload_upd["status"] = st_id
        tags = _parse_tags(args.tags)
        if tags is not None:
            payload_upd["tags"] = tags
        if args.dry_run:
            print(
                f"[dry-run] Would PATCH /api/v1/tasks/{args.task_id} with payload: {json.dumps(payload_upd)}"
            )
            return 0
        status, data = client.request("PATCH", f"/api/v1/tasks/{args.task_id}", payload=payload_upd)
        if status != 200:
            sys.exit(f"[error] Failed to update task (HTTP {status}: {data})")
        print(f"[ok] Updated task id={args.task_id}")
        return 0

    if action == "delete":
        if args.dry_run:
            print(f"[dry-run] Would DELETE /api/v1/tasks/{args.task_id}")
            return 0
        status, data = client.request("DELETE", f"/api/v1/tasks/{args.task_id}")
        if status not in (200, 204):
            sys.exit(f"[error] Failed to delete task (HTTP {status}: {data})")
        print(f"[ok] Deleted task id={args.task_id}")
        return 0

    return 1


def handle_issues(client: TaigaClient, args: argparse.Namespace) -> int:
    action = args.issues_action
    if action == "list":
        proj = client.resolve_project(args.project)
        proj_id = proj["id"]
        params = [f"project={proj_id}"]
        if args.status:
            st_id = _find_named_id(proj.get("issue_statuses"), args.status)
            if st_id is not None:
                params.append(f"status={st_id}")
        if args.type:
            t_id = _find_named_id(proj.get("issue_types"), args.type)
            if t_id is not None:
                params.append(f"type={t_id}")
        if args.priority:
            p_id = _find_named_id(proj.get("priorities"), args.priority)
            if p_id is not None:
                params.append(f"priority={p_id}")
        if args.severity:
            s_id = _find_named_id(proj.get("severities"), args.severity)
            if s_id is not None:
                params.append(f"severity={s_id}")
        status, data = client.request("GET", "/api/v1/issues?" + "&".join(params))
        if status != 200 or not isinstance(data, list):
            sys.exit(f"[error] Failed to list issues (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
            return 0
        print(f"Issues in '{proj.get('name')}' ({len(data)}):")
        for i in data:
            if not isinstance(i, dict):
                continue
            st_extra = i.get("status_extra_info") or {}
            st_name = st_extra.get("name") if isinstance(st_extra, dict) else i.get("status")
            print(
                f"  - id={i.get('id')} (#{i.get('ref')}) [{st_name}] {i.get('subject')}"
            )
        return 0

    if action == "get":
        status, data = client.request("GET", f"/api/v1/issues/{args.issue_id}")
        if status != 200 or not isinstance(data, dict):
            sys.exit(f"[error] Issue {args.issue_id} not found (HTTP {status}: {data})")
        _print_output(data, as_json=args.json)
        return 0

    if action == "create":
        proj = client.resolve_project(args.project)
        proj_id = proj["id"]
        payload: dict[str, Any] = {
            "project": proj_id,
            "subject": args.subject,
        }
        if args.description:
            payload["description"] = args.description
        if args.status:
            st_id = _find_named_id(proj.get("issue_statuses"), args.status)
            if st_id is None:
                sys.exit(f"[error] Unknown issue status '{args.status}'.")
            payload["status"] = st_id
        if args.type:
            t_id = _find_named_id(proj.get("issue_types"), args.type)
            if t_id is None:
                sys.exit(f"[error] Unknown issue type '{args.type}'.")
            payload["type"] = t_id
        if args.priority:
            p_id = _find_named_id(proj.get("priorities"), args.priority)
            if p_id is None:
                sys.exit(f"[error] Unknown priority '{args.priority}'.")
            payload["priority"] = p_id
        if args.severity:
            s_id = _find_named_id(proj.get("severities"), args.severity)
            if s_id is None:
                sys.exit(f"[error] Unknown severity '{args.severity}'.")
            payload["severity"] = s_id
        if args.sprint:
            payload["milestone"] = _resolve_sprint_id(client, proj_id, args.sprint)
        tags = _parse_tags(args.tags)
        if tags is not None:
            payload["tags"] = tags
        if args.assign_to_me:
            payload["assigned_to"] = client.get_current_user_id()
        if args.dry_run:
            print(f"[dry-run] Would POST /api/v1/issues with payload: {json.dumps(payload)}")
            return 0
        status, data = client.request("POST", "/api/v1/issues", payload=payload)
        if status not in (200, 201) or not isinstance(data, dict):
            sys.exit(f"[error] Failed to create issue (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
        else:
            print(
                f"[ok] Created issue id={data.get('id')} (#{data.get('ref')}) '{data.get('subject')}'"
            )
        return 0

    if action == "update":
        cur_status, cur_issue = client.request("GET", f"/api/v1/issues/{args.issue_id}")
        if cur_status != 200 or not isinstance(cur_issue, dict):
            sys.exit(f"[error] Issue {args.issue_id} not found (HTTP {cur_status}: {cur_issue})")
        proj = client.resolve_project(str(cur_issue["project"]))
        payload_upd: dict[str, Any] = {"version": cur_issue["version"]}
        if args.subject:
            payload_upd["subject"] = args.subject
        if args.description is not None:
            payload_upd["description"] = args.description
        if args.status:
            st_id = _find_named_id(proj.get("issue_statuses"), args.status)
            if st_id is None:
                sys.exit(f"[error] Unknown issue status '{args.status}'.")
            payload_upd["status"] = st_id
        if args.type:
            t_id = _find_named_id(proj.get("issue_types"), args.type)
            if t_id is None:
                sys.exit(f"[error] Unknown issue type '{args.type}'.")
            payload_upd["type"] = t_id
        if args.priority:
            p_id = _find_named_id(proj.get("priorities"), args.priority)
            if p_id is None:
                sys.exit(f"[error] Unknown priority '{args.priority}'.")
            payload_upd["priority"] = p_id
        if args.severity:
            s_id = _find_named_id(proj.get("severities"), args.severity)
            if s_id is None:
                sys.exit(f"[error] Unknown severity '{args.severity}'.")
            payload_upd["severity"] = s_id
        tags = _parse_tags(args.tags)
        if tags is not None:
            payload_upd["tags"] = tags
        if args.dry_run:
            print(
                f"[dry-run] Would PATCH /api/v1/issues/{args.issue_id} with payload: {json.dumps(payload_upd)}"
            )
            return 0
        status, data = client.request(
            "PATCH", f"/api/v1/issues/{args.issue_id}", payload=payload_upd
        )
        if status != 200:
            sys.exit(f"[error] Failed to update issue (HTTP {status}: {data})")
        print(f"[ok] Updated issue id={args.issue_id}")
        return 0

    if action == "delete":
        if args.dry_run:
            print(f"[dry-run] Would DELETE /api/v1/issues/{args.issue_id}")
            return 0
        status, data = client.request("DELETE", f"/api/v1/issues/{args.issue_id}")
        if status not in (200, 204):
            sys.exit(f"[error] Failed to delete issue (HTTP {status}: {data})")
        print(f"[ok] Deleted issue id={args.issue_id}")
        return 0

    return 1


def handle_epics(client: TaigaClient, args: argparse.Namespace) -> int:
    action = args.epics_action
    if action == "list":
        proj = client.resolve_project(args.project)
        status, data = client.request("GET", f"/api/v1/epics?project={proj['id']}")
        if status != 200 or not isinstance(data, list):
            sys.exit(f"[error] Failed to list epics (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
            return 0
        print(f"Epics in '{proj.get('name')}' ({len(data)}):")
        for e in data:
            if not isinstance(e, dict):
                continue
            st_extra = e.get("status_extra_info") or {}
            st_name = st_extra.get("name") if isinstance(st_extra, dict) else e.get("status")
            print(f"  - id={e.get('id')} (#{e.get('ref')}) [{st_name}] {e.get('subject')}")
        return 0

    if action == "get":
        status, data = client.request("GET", f"/api/v1/epics/{args.epic_id}")
        if status != 200 or not isinstance(data, dict):
            sys.exit(f"[error] Epic {args.epic_id} not found (HTTP {status}: {data})")
        _print_output(data, as_json=args.json)
        return 0

    if action == "create":
        proj = client.resolve_project(args.project)
        payload: dict[str, Any] = {
            "project": proj["id"],
            "subject": args.subject,
        }
        if args.description:
            payload["description"] = args.description
        if args.color:
            payload["color"] = args.color
        if args.status:
            st_id = _find_named_id(proj.get("epic_statuses"), args.status)
            if st_id is not None:
                payload["status"] = st_id
        tags = _parse_tags(args.tags)
        if tags is not None:
            payload["tags"] = tags
        if args.dry_run:
            print(f"[dry-run] Would POST /api/v1/epics with payload: {json.dumps(payload)}")
            return 0
        status, data = client.request("POST", "/api/v1/epics", payload=payload)
        if status not in (200, 201) or not isinstance(data, dict):
            sys.exit(f"[error] Failed to create epic (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
        else:
            print(
                f"[ok] Created epic id={data.get('id')} (#{data.get('ref')}) '{data.get('subject')}'"
            )
        return 0

    if action == "link-story":
        payload_link = {"epic": int(args.epic_id), "user_story": int(args.story_id)}
        if args.dry_run:
            print(
                f"[dry-run] Would POST /api/v1/epics/{args.epic_id}/related_userstories with payload: {json.dumps(payload_link)}"
            )
            return 0
        status, data = client.request(
            "POST",
            f"/api/v1/epics/{args.epic_id}/related_userstories",
            payload=payload_link,
        )
        if status not in (200, 201):
            sys.exit(f"[error] Failed to link story to epic (HTTP {status}: {data})")
        print(f"[ok] Linked user story {args.story_id} to epic {args.epic_id}")
        return 0

    if action == "delete":
        if args.dry_run:
            print(f"[dry-run] Would DELETE /api/v1/epics/{args.epic_id}")
            return 0
        status, data = client.request("DELETE", f"/api/v1/epics/{args.epic_id}")
        if status not in (200, 204):
            sys.exit(f"[error] Failed to delete epic (HTTP {status}: {data})")
        print(f"[ok] Deleted epic id={args.epic_id}")
        return 0

    return 1


def handle_wiki(client: TaigaClient, args: argparse.Namespace) -> int:
    action = args.wiki_action
    proj = client.resolve_project(args.project)
    proj_id = proj["id"]

    if action == "list":
        status, data = client.request("GET", f"/api/v1/wiki?project={proj_id}")
        if status != 200 or not isinstance(data, list):
            sys.exit(f"[error] Failed to list wiki pages (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
            return 0
        print(f"Wiki Pages in '{proj.get('name')}' ({len(data)}):")
        for w in data:
            if isinstance(w, dict):
                print(f"  - [{w.get('id')}] slug={w.get('slug')} (modified={w.get('modified_date')})")
        return 0

    if action == "get":
        slug = urllib.parse.quote(args.slug)
        status, data = client.request(
            "GET", f"/api/v1/wiki/by_slug?project={proj_id}&slug={slug}"
        )
        if status != 200 or not isinstance(data, dict):
            sys.exit(f"[error] Wiki page '{args.slug}' not found (HTTP {status}: {data})")
        if args.json:
            _print_output(data, as_json=True)
        else:
            print(data.get("content", ""))
        return 0

    if action == "set":
        slug = urllib.parse.quote(args.slug)
        status, existing = client.request(
            "GET", f"/api/v1/wiki/by_slug?project={proj_id}&slug={slug}"
        )
        if status == 200 and isinstance(existing, dict) and existing.get("id"):
            wiki_id = existing["id"]
            payload_upd = {
                "content": args.content,
                "version": existing["version"],
            }
            if args.dry_run:
                print(
                    f"[dry-run] Would PATCH /api/v1/wiki/{wiki_id} (slug={args.slug})"
                )
                return 0
            upd_status, upd_data = client.request(
                "PATCH", f"/api/v1/wiki/{wiki_id}", payload=payload_upd
            )
            if upd_status != 200:
                sys.exit(f"[error] Failed to update wiki page (HTTP {upd_status}: {upd_data})")
            print(f"[ok] Updated wiki page '{args.slug}' in '{proj.get('name')}'")
            return 0

        payload_new = {
            "project": proj_id,
            "slug": args.slug,
            "content": args.content,
        }
        if args.dry_run:
            print(f"[dry-run] Would POST /api/v1/wiki (slug={args.slug})")
            return 0
        new_status, new_data = client.request("POST", "/api/v1/wiki", payload=payload_new)
        if new_status not in (200, 201):
            sys.exit(f"[error] Failed to create wiki page (HTTP {new_status}: {new_data})")
        print(f"[ok] Created wiki page '{args.slug}' in '{proj.get('name')}'")
        return 0

    if action == "delete":
        slug = urllib.parse.quote(args.slug)
        status, existing = client.request(
            "GET", f"/api/v1/wiki/by_slug?project={proj_id}&slug={slug}"
        )
        if status != 200 or not isinstance(existing, dict) or not existing.get("id"):
            sys.exit(f"[error] Wiki page '{args.slug}' not found.")
        wiki_id = existing["id"]
        if args.dry_run:
            print(f"[dry-run] Would DELETE /api/v1/wiki/{wiki_id} (slug={args.slug})")
            return 0
        del_status, del_data = client.request("DELETE", f"/api/v1/wiki/{wiki_id}")
        if del_status not in (200, 204):
            sys.exit(f"[error] Failed to delete wiki page (HTTP {del_status}: {del_data})")
        print(f"[ok] Deleted wiki page '{args.slug}'")
        return 0

    return 1


def handle_raw(client: TaigaClient, args: argparse.Namespace) -> int:
    method = args.method.upper()
    path = args.path if args.path.startswith("/") else f"/{args.path}"
    payload = json.loads(args.data) if args.data else None
    if args.dry_run and method != "GET":
        print(f"[dry-run] Would {method} {path} with payload: {json.dumps(payload)}")
        return 0
    status, data = client.request(method, path, payload=payload)
    print(json.dumps({"status": status, "data": data}, indent=2))
    return 0 if 200 <= status < 300 else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="CLI for managing Taiga projects, sprints, user stories, tasks, issues, epics, and wiki pages."
    )
    parser.add_argument(
        "--taiga-url",
        default=os.environ.get("TAIGA_URL", DEFAULT_TAIGA_URL),
        help=f"Base URL of the Taiga server (default: {DEFAULT_TAIGA_URL}).",
    )
    parser.add_argument(
        "--username",
        default=os.environ.get("TAIGA_ADMIN_USER", DEFAULT_ADMIN_USER),
        help=f"Taiga username (default: {DEFAULT_ADMIN_USER}).",
    )
    parser.add_argument(
        "--email",
        default=os.environ.get("TAIGA_ADMIN_EMAIL", DEFAULT_ADMIN_EMAIL),
        help=f"Taiga email fallback (default: {DEFAULT_ADMIN_EMAIL}).",
    )
    parser.add_argument(
        "--auth-token",
        default=os.environ.get("TAIGA_AUTH_TOKEN", ""),
        help="Optional Taiga Bearer auth token.",
    )
    parser.add_argument(
        "--fallback-sni",
        default=DEFAULT_FALLBACK_SNI,
        help=f"Fallback TLS SNI hostname (default: {DEFAULT_FALLBACK_SNI}).",
    )

    subparsers = parser.add_subparsers(dest="resource", required=True)

    # --- projects ---
    p_proj = subparsers.add_parser("projects", help="Manage Taiga projects.")
    proj_sub = p_proj.add_subparsers(dest="projects_action", required=True)

    proj_list = proj_sub.add_parser("list", help="List projects.")
    proj_list.add_argument(
        "--member-only",
        action="store_true",
        default=True,
        help="List projects ordered by user_order (default: True).",
    )
    proj_list.add_argument("--search", help="Filter projects by name, slug, or description.")
    proj_list.add_argument("--json", action="store_true", help="Output raw JSON.")

    proj_get = proj_sub.add_parser("get", help="Get project details, statuses, and points.")
    proj_get.add_argument("project", help="Project ID, slug, or name.")
    proj_get.add_argument("--json", action="store_true", help="Output raw JSON.")

    proj_create = proj_sub.add_parser("create", help="Create a new project.")
    proj_create.add_argument("--name", required=True, help="Project name.")
    proj_create.add_argument("--description", default="", help="Project description.")
    proj_create.add_argument(
        "--template", choices=["scrum", "kanban"], default="scrum", help="Methodology template."
    )
    proj_create.add_argument("--public", action="store_true", help="Create as public.")
    proj_create.add_argument("--tags", help="Comma-separated tags.")
    proj_create.add_argument("--json", action="store_true", help="Output raw JSON.")
    proj_create.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    proj_upd = proj_sub.add_parser("update", help="Update an existing project.")
    proj_upd.add_argument("project", help="Project ID, slug, or name.")
    proj_upd.add_argument("--name", help="New project name.")
    proj_upd.add_argument("--description", help="New project description.")
    proj_upd.add_argument("--template", choices=["scrum", "kanban"], help="Switch template.")
    proj_upd.add_argument("--public", action="store_true", help="Set project public.")
    proj_upd.add_argument("--private", action="store_true", help="Set project private.")
    proj_upd.add_argument("--tags", help="Comma-separated tags.")
    proj_upd.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    proj_del = proj_sub.add_parser("delete", help="Delete a project.")
    proj_del.add_argument("project", help="Project ID, slug, or name.")
    proj_del.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    # --- sprints ---
    p_sprints = subparsers.add_parser("sprints", help="Manage Scrum sprints (milestones).")
    sprints_sub = p_sprints.add_subparsers(dest="sprints_action", required=True)

    sp_list = sprints_sub.add_parser("list", help="List sprints in a project.")
    sp_list.add_argument("project", help="Project ID, slug, or name.")
    sp_list.add_argument("--open", action="store_true", help="Only open sprints.")
    sp_list.add_argument("--closed", action="store_true", help="Only closed sprints.")
    sp_list.add_argument("--json", action="store_true", help="Output raw JSON.")

    sp_get = sprints_sub.add_parser("get", help="Get sprint details.")
    sp_get.add_argument("sprint_id", type=int, help="Sprint (milestone) ID.")
    sp_get.add_argument("--json", action="store_true", help="Output raw JSON.")

    sp_create = sprints_sub.add_parser("create", help="Create a sprint in a project.")
    sp_create.add_argument("project", help="Project ID, slug, or name.")
    sp_create.add_argument("--name", required=True, help="Sprint name (e.g., 'Sprint 1').")
    sp_create.add_argument("--start", required=True, help="Start date (YYYY-MM-DD).")
    sp_create.add_argument("--end", required=True, help="End date (YYYY-MM-DD).")
    sp_create.add_argument("--json", action="store_true", help="Output raw JSON.")
    sp_create.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    sp_upd = sprints_sub.add_parser("update", help="Update or close/reopen a sprint.")
    sp_upd.add_argument("sprint_id", type=int, help="Sprint (milestone) ID.")
    sp_upd.add_argument("--name", help="New sprint name.")
    sp_upd.add_argument("--start", help="New start date (YYYY-MM-DD).")
    sp_upd.add_argument("--end", help="New end date (YYYY-MM-DD).")
    sp_upd.add_argument("--closed", action="store_true", help="Mark sprint as closed.")
    sp_upd.add_argument("--open", action="store_true", help="Reopen sprint.")
    sp_upd.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    sp_del = sprints_sub.add_parser("delete", help="Delete a sprint.")
    sp_del.add_argument("sprint_id", type=int, help="Sprint (milestone) ID.")
    sp_del.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    # --- stories ---
    p_stories = subparsers.add_parser("stories", help="Manage user stories (backlog & sprint items).")
    stories_sub = p_stories.add_subparsers(dest="stories_action", required=True)

    st_list = stories_sub.add_parser("list", help="List user stories in a project.")
    st_list.add_argument("project", help="Project ID, slug, or name.")
    st_list.add_argument(
        "--sprint", help="Filter by sprint ID/name, or 'backlog' for unassigned stories."
    )
    st_list.add_argument("--status", help="Filter by status name (e.g., 'New', 'In progress', 'Done').")
    st_list.add_argument("--tag", help="Filter by tag.")
    st_list.add_argument("--json", action="store_true", help="Output raw JSON.")

    st_get = stories_sub.add_parser("get", help="Get user story details.")
    st_get.add_argument("story_id", type=int, help="User story ID (or ref number if --by-ref).")
    st_get.add_argument("--by-ref", action="store_true", help="Lookup by project #ref number.")
    st_get.add_argument("--project", help="Project ID, slug, or name (required with --by-ref).")
    st_get.add_argument("--json", action="store_true", help="Output raw JSON.")

    st_create = stories_sub.add_parser("create", help="Create a user story.")
    st_create.add_argument("project", help="Project ID, slug, or name.")
    st_create.add_argument("--subject", required=True, help="User story title/subject.")
    st_create.add_argument("--description", help="Markdown description.")
    st_create.add_argument("--status", help="Status name (e.g., 'New', 'Ready', 'In progress', 'Done').")
    st_create.add_argument("--points", help="Story points label (e.g., '1', '2', '3', '5', '8').")
    st_create.add_argument("--sprint", help="Sprint ID or name.")
    st_create.add_argument("--tags", help="Comma-separated tags.")
    st_create.add_argument("--assign-to-me", action="store_true", help="Assign to authenticated user.")
    st_create.add_argument("--json", action="store_true", help="Output raw JSON.")
    st_create.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    st_bulk = stories_sub.add_parser("bulk-create", help="Bulk-create multiple user stories.")
    st_bulk.add_argument("project", help="Project ID, slug, or name.")
    st_bulk.add_argument("--subjects", nargs="+", required=True, help="One or more story subjects.")
    st_bulk.add_argument("--sprint", help="Optional sprint ID or name.")
    st_bulk.add_argument("--status", help="Optional status name.")
    st_bulk.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    st_upd = stories_sub.add_parser("update", help="Update a user story.")
    st_upd.add_argument("story_id", type=int, help="User story ID.")
    st_upd.add_argument("--subject", help="New subject.")
    st_upd.add_argument("--description", help="New description.")
    st_upd.add_argument("--status", help="New status name (e.g., 'In progress', 'Done').")
    st_upd.add_argument("--points", help="New story points label (e.g., '3', '5').")
    st_upd.add_argument("--sprint", help="Sprint ID/name, or 'none' to move back to backlog.")
    st_upd.add_argument("--tags", help="Comma-separated tags.")
    st_upd.add_argument("--blocked-note", help="Mark blocked with a reason.")
    st_upd.add_argument("--unblock", action="store_true", help="Clear blocked status.")
    st_upd.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    st_del = stories_sub.add_parser("delete", help="Delete a user story.")
    st_del.add_argument("story_id", type=int, help="User story ID.")
    st_del.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    # --- tasks ---
    p_tasks = subparsers.add_parser("tasks", help="Manage tasks.")
    tasks_sub = p_tasks.add_subparsers(dest="tasks_action", required=True)

    tk_list = tasks_sub.add_parser("list", help="List tasks in a project.")
    tk_list.add_argument("project", help="Project ID, slug, or name.")
    tk_list.add_argument("--story", type=int, help="Filter by user story ID.")
    tk_list.add_argument("--sprint", help="Filter by sprint ID or name.")
    tk_list.add_argument("--status", help="Filter by status name.")
    tk_list.add_argument("--json", action="store_true", help="Output raw JSON.")

    tk_get = tasks_sub.add_parser("get", help="Get task details.")
    tk_get.add_argument("task_id", type=int, help="Task ID.")
    tk_get.add_argument("--json", action="store_true", help="Output raw JSON.")

    tk_create = tasks_sub.add_parser("create", help="Create a task.")
    tk_create.add_argument("project", help="Project ID, slug, or name.")
    tk_create.add_argument("--subject", required=True, help="Task subject.")
    tk_create.add_argument("--description", help="Task description.")
    tk_create.add_argument("--story", type=int, help="Parent user story ID.")
    tk_create.add_argument("--sprint", help="Sprint ID or name.")
    tk_create.add_argument("--status", help="Task status name (e.g., 'New', 'In progress', 'Closed').")
    tk_create.add_argument("--tags", help="Comma-separated tags.")
    tk_create.add_argument("--assign-to-me", action="store_true", help="Assign to authenticated user.")
    tk_create.add_argument("--json", action="store_true", help="Output raw JSON.")
    tk_create.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    tk_upd = tasks_sub.add_parser("update", help="Update a task.")
    tk_upd.add_argument("task_id", type=int, help="Task ID.")
    tk_upd.add_argument("--subject", help="New subject.")
    tk_upd.add_argument("--description", help="New description.")
    tk_upd.add_argument("--story", help="User story ID (or 'none').")
    tk_upd.add_argument("--status", help="New status name.")
    tk_upd.add_argument("--tags", help="Comma-separated tags.")
    tk_upd.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    tk_del = tasks_sub.add_parser("delete", help="Delete a task.")
    tk_del.add_argument("task_id", type=int, help="Task ID.")
    tk_del.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    # --- issues ---
    p_issues = subparsers.add_parser("issues", help="Manage project issues & bugs.")
    issues_sub = p_issues.add_subparsers(dest="issues_action", required=True)

    is_list = issues_sub.add_parser("list", help="List issues in a project.")
    is_list.add_argument("project", help="Project ID, slug, or name.")
    is_list.add_argument("--status", help="Filter by status (e.g., 'New', 'In progress', 'Closed').")
    is_list.add_argument("--type", help="Filter by type (e.g., 'Bug', 'Question', 'Enhancement').")
    is_list.add_argument("--priority", help="Filter by priority ('Low', 'Normal', 'High').")
    is_list.add_argument(
        "--severity",
        help="Filter by severity ('Wishlist', 'Minor', 'Normal', 'Important', 'Critical').",
    )
    is_list.add_argument("--json", action="store_true", help="Output raw JSON.")

    is_get = issues_sub.add_parser("get", help="Get issue details.")
    is_get.add_argument("issue_id", type=int, help="Issue ID.")
    is_get.add_argument("--json", action="store_true", help="Output raw JSON.")

    is_create = issues_sub.add_parser("create", help="Create an issue.")
    is_create.add_argument("project", help="Project ID, slug, or name.")
    is_create.add_argument("--subject", required=True, help="Issue subject.")
    is_create.add_argument("--description", help="Issue description.")
    is_create.add_argument("--status", help="Issue status (e.g., 'New', 'In progress', 'Closed').")
    is_create.add_argument("--type", help="Issue type ('Bug', 'Question', 'Enhancement').")
    is_create.add_argument("--priority", help="Priority ('Low', 'Normal', 'High').")
    is_create.add_argument(
        "--severity", help="Severity ('Wishlist', 'Minor', 'Normal', 'Important', 'Critical')."
    )
    is_create.add_argument("--sprint", help="Sprint ID or name.")
    is_create.add_argument("--tags", help="Comma-separated tags.")
    is_create.add_argument("--assign-to-me", action="store_true", help="Assign to authenticated user.")
    is_create.add_argument("--json", action="store_true", help="Output raw JSON.")
    is_create.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    is_upd = issues_sub.add_parser("update", help="Update an issue.")
    is_upd.add_argument("issue_id", type=int, help="Issue ID.")
    is_upd.add_argument("--subject", help="New subject.")
    is_upd.add_argument("--description", help="New description.")
    is_upd.add_argument("--status", help="New status.")
    is_upd.add_argument("--type", help="New type.")
    is_upd.add_argument("--priority", help="New priority.")
    is_upd.add_argument("--severity", help="New severity.")
    is_upd.add_argument("--tags", help="Comma-separated tags.")
    is_upd.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    is_del = issues_sub.add_parser("delete", help="Delete an issue.")
    is_del.add_argument("issue_id", type=int, help="Issue ID.")
    is_del.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    # --- epics ---
    p_epics = subparsers.add_parser("epics", help="Manage project epics.")
    epics_sub = p_epics.add_subparsers(dest="epics_action", required=True)

    ep_list = epics_sub.add_parser("list", help="List epics in a project.")
    ep_list.add_argument("project", help="Project ID, slug, or name.")
    ep_list.add_argument("--json", action="store_true", help="Output raw JSON.")

    ep_get = epics_sub.add_parser("get", help="Get epic details.")
    ep_get.add_argument("epic_id", type=int, help="Epic ID.")
    ep_get.add_argument("--json", action="store_true", help="Output raw JSON.")

    ep_create = epics_sub.add_parser("create", help="Create an epic.")
    ep_create.add_argument("project", help="Project ID, slug, or name.")
    ep_create.add_argument("--subject", required=True, help="Epic subject.")
    ep_create.add_argument("--description", help="Epic description.")
    ep_create.add_argument("--status", help="Epic status name.")
    ep_create.add_argument("--color", help="Hex color (e.g. '#A569BD').")
    ep_create.add_argument("--tags", help="Comma-separated tags.")
    ep_create.add_argument("--json", action="store_true", help="Output raw JSON.")
    ep_create.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    ep_link = epics_sub.add_parser("link-story", help="Link a user story to an epic.")
    ep_link.add_argument("epic_id", type=int, help="Epic ID.")
    ep_link.add_argument("--story-id", type=int, required=True, help="User story ID.")
    ep_link.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    ep_del = epics_sub.add_parser("delete", help="Delete an epic.")
    ep_del.add_argument("epic_id", type=int, help="Epic ID.")
    ep_del.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    # --- wiki ---
    p_wiki = subparsers.add_parser("wiki", help="Manage project wiki pages.")
    wiki_sub = p_wiki.add_subparsers(dest="wiki_action", required=True)

    wk_list = wiki_sub.add_parser("list", help="List wiki pages in a project.")
    wk_list.add_argument("project", help="Project ID, slug, or name.")
    wk_list.add_argument("--json", action="store_true", help="Output raw JSON.")

    wk_get = wiki_sub.add_parser("get", help="Get wiki page content by slug.")
    wk_get.add_argument("project", help="Project ID, slug, or name.")
    wk_get.add_argument("--slug", required=True, help="Wiki page slug (e.g., 'home').")
    wk_get.add_argument("--json", action="store_true", help="Output raw JSON.")

    wk_set = wiki_sub.add_parser("set", help="Create or update a wiki page by slug.")
    wk_set.add_argument("project", help="Project ID, slug, or name.")
    wk_set.add_argument("--slug", required=True, help="Wiki page slug (e.g., 'home').")
    wk_set.add_argument("--content", required=True, help="Markdown content.")
    wk_set.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    wk_del = wiki_sub.add_parser("delete", help="Delete a wiki page by slug.")
    wk_del.add_argument("project", help="Project ID, slug, or name.")
    wk_del.add_argument("--slug", required=True, help="Wiki page slug.")
    wk_del.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    # --- raw ---
    p_raw = subparsers.add_parser("raw", help="Send a raw authenticated request to /api/v1/...")
    p_raw.add_argument(
        "method", choices=["GET", "POST", "PATCH", "PUT", "DELETE"], help="HTTP method."
    )
    p_raw.add_argument("path", help="API path (e.g., '/api/v1/users/me').")
    p_raw.add_argument("--data", help="JSON body string.")
    p_raw.add_argument("--dry-run", action="store_true", help="Preview without mutating.")

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    password = os.environ.get("TAIGA_ADMIN_PASSWORD", "")
    client = TaigaClient(
        taiga_url=args.taiga_url,
        username=args.username,
        email=args.email,
        password=password,
        auth_token=args.auth_token,
        fallback_sni=args.fallback_sni,
    )

    dispatch = {
        "projects": handle_projects,
        "sprints": handle_sprints,
        "stories": handle_stories,
        "tasks": handle_tasks,
        "issues": handle_issues,
        "epics": handle_epics,
        "wiki": handle_wiki,
        "raw": handle_raw,
    }
    handler = dispatch.get(args.resource)
    if handler is None:
        parser.print_help()
        sys.exit(1)
    sys.exit(handler(client, args))


if __name__ == "__main__":
    main()
