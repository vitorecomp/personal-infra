#!/usr/bin/env python3
"""Creates or updates documentation/repo_stats.csv with all GitHub repositories.

Columns:
    name, link, ssh link, last updated, is a fork, folder, is-custom, is-template

When documentation/repo_stats.csv already exists, existing rows are matched by
`name` and only changed GitHub metadata fields (`link`, `ssh link`,
`last updated`, `is a fork`) are updated, preserving manual values in
`folder`, `is-custom`, and `is-template`. All rows are ordered by
`last updated` descending (most recently updated first).
"""

import argparse
import csv
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

USER = "vitorecomp"
REPO_ROOT = Path(__file__).resolve().parent.parent
DOC_DIR = REPO_ROOT / "documentation"
CSV_PATH = DOC_DIR / "repo_stats.csv"

FIELDNAMES = [
    "name",
    "link",
    "ssh link",
    "last updated",
    "is a fork",
    "folder",
    "is-custom",
    "is-template",
]

TRACKED_FIELDS = ("link", "ssh link", "last updated", "is a fork")
EMPTY_FIELDS = ("folder", "is-custom", "is-template")


def fetch_page(url: str, token: str | None) -> list[dict]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "vitorecomp-repo-stats-script",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def fetch_all_repos(user: str, token: str | None) -> list[dict]:
    repos: list[dict] = []
    page = 1
    use_authenticated_endpoint = bool(token)

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
            batch = fetch_page(url, token)
        except urllib.error.HTTPError as err:
            if use_authenticated_endpoint and err.code in (401, 403):
                # Fallback to public user endpoint if token lacks /user/repos access
                use_authenticated_endpoint = False
                continue
            raise

        if not batch:
            break

        repos.extend(batch)
        if len(batch) < 100:
            break
        page += 1

    return repos


def load_existing_csv(csv_path: Path) -> list[dict[str, str]]:
    if not csv_path.exists():
        return []

    rows: list[dict[str, str]] = []
    with csv_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            name = (row.get("name") or "").strip()
            if not name:
                continue
            rows.append({
                field: row.get(field, "") or "" for field in FIELDNAMES
            })
    return rows


def build_repo_row(repo: dict) -> dict[str, str]:
    return {
        "name": repo["name"],
        "link": repo["html_url"],
        "ssh link": repo["ssh_url"],
        "last updated": repo.get("updated_at") or repo.get("pushed_at") or "",
        "is a fork": str(bool(repo.get("fork", False))),
        "folder": "",
        "is-custom": "",
        "is-template": "",
    }


def sort_rows_by_last_updated(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    """Sorts rows by `last updated` descending (most recent first), with `name` ascending as tie-breaker."""
    by_name = sorted(rows, key=lambda r: (r.get("name") or "").lower())
    return sorted(
        by_name,
        key=lambda r: r.get("last updated") or "",
        reverse=True,
    )


def update_repo_stats(csv_path: Path = CSV_PATH, dry_run: bool = False) -> None:
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("METRICS_TOKEN")
    csv_path.parent.mkdir(parents=True, exist_ok=True)

    file_existed = csv_path.exists()
    existing_rows = load_existing_csv(csv_path)
    original_snapshot = [dict(row) for row in existing_rows]

    repos = fetch_all_repos(USER, token)
    fresh_by_name = {repo["name"]: build_repo_row(repo) for repo in repos}

    added_count = 0
    updated_count = 0
    unchanged_count = 0

    merged_rows: list[dict[str, str]] = []
    seen_names: set[str] = set()

    # Update existing rows while preserving manual columns.
    for row in existing_rows:
        name = row["name"]
        seen_names.add(name)
        row_copy = dict(row)
        fresh = fresh_by_name.get(name)
        if not fresh:
            merged_rows.append(row_copy)
            unchanged_count += 1
            continue

        changed = False
        for field in TRACKED_FIELDS:
            if row_copy.get(field, "") != fresh[field]:
                row_copy[field] = fresh[field]
                changed = True
        for field in EMPTY_FIELDS:
            row_copy.setdefault(field, "")

        if changed:
            updated_count += 1
        else:
            unchanged_count += 1
        merged_rows.append(row_copy)

    # Include newly discovered repositories.
    for repo in repos:
        name = repo["name"]
        if name not in seen_names:
            seen_names.add(name)
            added_count += 1
            merged_rows.append(fresh_by_name[name])

    # Sort all rows by `last updated` descending (most recently updated first).
    final_rows = sort_rows_by_last_updated(merged_rows)
    reordered = final_rows != original_snapshot

    if not file_existed or added_count > 0 or updated_count > 0 or reordered:
        if dry_run:
            print(
                f"[dry-run] Would write {csv_path}: total={len(final_rows)}, "
                f"added={added_count}, updated={updated_count}, "
                f"unchanged={unchanged_count}, reordered={reordered}"
            )
            return

        with csv_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(
                handle, fieldnames=FIELDNAMES, lineterminator="\n"
            )
            writer.writeheader()
            writer.writerows(final_rows)

    print(
        f"{csv_path}: total={len(final_rows)}, "
        f"added={added_count}, updated={updated_count}, "
        f"unchanged={unchanged_count}, reordered={reordered}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Update documentation/repo_stats.csv with GitHub metadata ordered by last updated."
    )
    parser.add_argument(
        "--csv",
        type=Path,
        default=CSV_PATH,
        help=f"Path to repo_stats.csv (default: {CSV_PATH})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview changes without writing to repo_stats.csv.",
    )
    args = parser.parse_args()
    update_repo_stats(csv_path=args.csv.expanduser().resolve(), dry_run=args.dry_run)


if __name__ == "__main__":
    main()
