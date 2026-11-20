#!/usr/bin/env python3
"""Creates or updates documentation/repo_stats.json with all GitHub repositories.

Schema (object keyed by repository name, sorted alphabetically):
    {
      "<name>": {
        "last_updated": "<ISO-8601 UTC timestamp>",
        "link": "https://github.com/vitorecomp/<name>",
        "ssh_link": "git@github.com:vitorecomp/<name>.git",
        "is_fork": false,
        "folder": "",
        "is_custom": false,
        "is_template": false
      }
    }

Field ordering intentionally places stable fields (`link`, `ssh_link`, `is_fork`)
between volatile `last_updated` and user-curated fields (`folder`, `is_custom`,
`is_template`) so Git's 3-way merge can auto-merge automated timestamp updates
with local folder edits without conflicts.

When documentation/repo_stats.json already exists, existing entries are matched
by repository name and only changed GitHub metadata fields (`last_updated`,
`link`, `ssh_link`, `is_fork`) are updated, preserving manual values in `folder`,
`is_custom`, and `is_template` (and never discarding existing entries).
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
from typing import Any
import urllib.error
import urllib.parse
import urllib.request

USER = "vitorecomp"
REPO_ROOT = Path(__file__).resolve().parent.parent
PROJECT_ROOT = REPO_ROOT.parent
DOC_DIR = REPO_ROOT / "documentation"
JSON_PATH = DOC_DIR / "repo_stats.json"

TRACKED_FIELDS = ("last_updated", "link", "ssh_link", "is_fork")
MANUAL_DEFAULTS: dict[str, Any] = {
    "folder": "",
    "is_custom": False,
    "is_template": False,
}
CANONICAL_FIELD_ORDER = (
    "last_updated",
    "link",
    "ssh_link",
    "is_fork",
    "folder",
    "is_custom",
    "is_template",
)


def _resolve_github_tokens() -> list[tuple[str, str]]:
    """Returns candidate (source, token) pairs from env vars, .env files, and `gh auth token`."""
    candidates: list[tuple[str, str]] = []
    seen: set[str] = set()

    for key in ("GITHUB_TOKEN", "METRICS_TOKEN"):
        val = (os.environ.get(key) or "").strip()
        if val and val not in seen:
            seen.add(val)
            candidates.append((f"env:{key}", val))

    for env_path in (PROJECT_ROOT / ".env", REPO_ROOT / ".env"):
        if not env_path.exists():
            continue
        try:
            for raw_line in env_path.read_text(encoding="utf-8").splitlines():
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                if line.startswith("export "):
                    line = line[len("export ") :].strip()
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip().strip("'").strip('"')
                if k in ("GITHUB_TOKEN", "METRICS_TOKEN") and v and v not in seen:
                    seen.add(v)
                    candidates.append((f"file:{env_path.name}:{k}", v))
        except OSError:
            continue

    try:
        res = subprocess.run(
            ["gh", "auth", "token"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        gh_tok = res.stdout.strip()
        if res.returncode == 0 and gh_tok and gh_tok not in seen:
            seen.add(gh_tok)
            candidates.append(("gh-cli", gh_tok))
    except Exception:
        pass

    return candidates


def fetch_page(url: str, token: str | None) -> list[dict[str, Any]]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "vitorecomp-repo-stats-script",
        "Cache-Control": "no-cache",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def fetch_all_repos(user: str, token_candidates: list[tuple[str, str]]) -> list[dict[str, Any]]:
    # Try each candidate token against /user/repos first, then fall back to unauthenticated /users/<user>/repos.
    attempts: list[tuple[str, str | None, bool]] = [
        (src, tok, True) for src, tok in token_candidates
    ]
    attempts.append(("unauthenticated", None, False))

    for source_label, active_token, use_authenticated_endpoint in attempts:
        repos: list[dict[str, Any]] = []
        page = 1
        failed_attempt = False

        while True:
            if use_authenticated_endpoint:
                params = urllib.parse.urlencode({
                    "per_page": 100,
                    "affiliation": "owner",
                    "sort": "updated",
                    "direction": "desc",
                    "page": page,
                })
                url = f"https://api.github.com/user/repos?{params}"
            else:
                params = urllib.parse.urlencode({
                    "per_page": 100,
                    "type": "owner",
                    "sort": "updated",
                    "direction": "desc",
                    "page": page,
                })
                url = f"https://api.github.com/users/{user}/repos?{params}"

            try:
                batch = fetch_page(url, active_token)
            except urllib.error.HTTPError as err:
                err_body = ""
                try:
                    err_body = err.read().decode("utf-8", errors="replace").strip()
                except Exception:
                    pass
                print(
                    f"[warn] GitHub API HTTP {err.code} using {source_label}: {err_body[:200]}"
                )
                failed_attempt = True
                break

            if not batch:
                break

            repos.extend(batch)
            if len(batch) < 100:
                break
            page += 1

        if not failed_attempt:
            return repos

    return []


def _normalize_entry(entry: dict[str, Any]) -> dict[str, Any]:
    """Returns a copy of a repo entry with canonical key ordering and defaults."""
    normalized: dict[str, Any] = {}
    for field in CANONICAL_FIELD_ORDER:
        if field in entry:
            normalized[field] = entry[field]
        elif field in MANUAL_DEFAULTS:
            normalized[field] = MANUAL_DEFAULTS[field]
        elif field == "is_fork":
            normalized[field] = False
        else:
            normalized[field] = ""
    # Preserve any extra user-added fields after canonical fields.
    for key, val in entry.items():
        if key not in normalized:
            normalized[key] = val
    return normalized


def load_existing_json(json_path: Path) -> dict[str, dict[str, Any]]:
    if not json_path.exists():
        return {}

    raw = json.loads(json_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError(f"Expected top-level JSON object in {json_path}")

    entries: dict[str, dict[str, Any]] = {}
    for name, value in raw.items():
        clean_name = str(name).strip()
        if not clean_name or not isinstance(value, dict):
            continue
        entries[clean_name] = _normalize_entry(value)
    return entries


def build_repo_entry(repo: dict[str, Any]) -> dict[str, Any]:
    updated_at = str(repo.get("updated_at") or "")
    pushed_at = str(repo.get("pushed_at") or "")
    latest_ts = max(updated_at, pushed_at)
    return {
        "last_updated": latest_ts,
        "link": str(repo["html_url"]),
        "ssh_link": str(repo["ssh_url"]),
        "is_fork": bool(repo.get("fork", False)),
        "folder": "",
        "is_custom": False,
        "is_template": False,
    }


def sort_entries_alphabetically(
    entries: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    """Sorts repository entries alphabetically by name (case-insensitive, stable tie-breaker)."""
    return {
        name: _normalize_entry(entries[name])
        for name in sorted(entries.keys(), key=lambda n: (n.lower(), n))
    }


def update_repo_stats(json_path: Path = JSON_PATH, dry_run: bool = False) -> None:
    token_candidates = _resolve_github_tokens()
    json_path.parent.mkdir(parents=True, exist_ok=True)

    file_existed = json_path.exists()
    original_text = json_path.read_text(encoding="utf-8") if file_existed else ""
    existing_entries = load_existing_json(json_path)

    repos = fetch_all_repos(USER, token_candidates)
    fresh_by_name = {repo["name"]: build_repo_entry(repo) for repo in repos}

    added_count = 0
    updated_count = 0
    unchanged_count = 0

    merged: dict[str, dict[str, Any]] = {}

    # Update existing entries while preserving manual fields (never discard existing repos).
    for name, entry in existing_entries.items():
        entry_copy = dict(entry)
        fresh = fresh_by_name.get(name)
        if not fresh:
            merged[name] = entry_copy
            unchanged_count += 1
            continue

        changed = False
        for field in TRACKED_FIELDS:
            if entry_copy.get(field) != fresh[field]:
                entry_copy[field] = fresh[field]
                changed = True
        for field, default_val in MANUAL_DEFAULTS.items():
            entry_copy.setdefault(field, default_val)

        if changed:
            updated_count += 1
        else:
            unchanged_count += 1
        merged[name] = entry_copy

    # Include newly discovered repositories.
    for repo in repos:
        name = repo["name"]
        if name not in merged:
            added_count += 1
            merged[name] = fresh_by_name[name]

    final_entries = sort_entries_alphabetically(merged)
    rendered = json.dumps(final_entries, indent=2, ensure_ascii=False) + "\n"
    reordered = file_existed and rendered != original_text and added_count == 0 and updated_count == 0

    if not file_existed or rendered != original_text:
        if dry_run:
            print(
                f"[dry-run] Would write {json_path}: total={len(final_entries)}, "
                f"added={added_count}, updated={updated_count}, "
                f"unchanged={unchanged_count}, reordered={reordered}"
            )
            return

        json_path.write_text(rendered, encoding="utf-8")

    print(
        f"{json_path}: total={len(final_entries)}, "
        f"added={added_count}, updated={updated_count}, "
        f"unchanged={unchanged_count}, reordered={reordered}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Update documentation/repo_stats.json with GitHub metadata sorted alphabetically."
    )
    parser.add_argument(
        "--json",
        type=Path,
        default=JSON_PATH,
        help=f"Path to repo_stats.json (default: {JSON_PATH})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview changes without writing to repo_stats.json.",
    )
    args = parser.parse_args()
    update_repo_stats(json_path=args.json.expanduser().resolve(), dry_run=args.dry_run)


if __name__ == "__main__":
    main()
