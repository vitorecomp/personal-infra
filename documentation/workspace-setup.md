# Workspace Management Setup

This document covers the local `~/workspace` orchestration tools located under [`workspace/`](../workspace).

---

## 1. Overview

The `workspace/` domain maintains a single source-of-truth CSV inventory of all `vitorecomp` GitHub repositories ([`workspace/documentation/repo_stats.csv`](../workspace/documentation/repo_stats.csv)) and automatically organizes and clones repositories into `~/workspace/<folder>/<name>`.

---

## 2. Repository Inventory (`repo_stats.csv`)

[`workspace/documentation/repo_stats.csv`](../workspace/documentation/repo_stats.csv) contains the following columns:

| Column | Managed By | Description |
| :--- | :--- | :--- |
| `name` | Automated (`update_repo_stats.py`) | GitHub repository name. |
| `link` | Automated (`update_repo_stats.py`) | HTTPS GitHub URL (`https://github.com/vitorecomp/<name>`). |
| `ssh link` | Automated (`update_repo_stats.py`) | SSH Git URL (`git@github.com:vitorecomp/<name>.git`). |
| `last updated` | Automated (`update_repo_stats.py`) | ISO 8601 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`); rows are sorted descending by this field. |
| `is a fork` | Automated (`update_repo_stats.py`) | `True` or `False`. |
| `folder` | **Manual (User-curated)** | Target category folder under `~/workspace/<folder>/<name>` (e.g., `personal`, `opensource`, `work`, `contribution`, `bench`, `portifolio`, `hackthon`). Empty `folder` rows are ignored by `sync_workspace_repos.py`. |
| `is-custom` | **Manual (User-curated)** | Custom flag preserved across automated syncs. |
| `is-template` | **Manual (User-curated)** | Template flag preserved across automated syncs. |

---

## 3. Scripts & Usage

### 3.1 Updating Repository Metadata (`update_repo_stats.py`)

Queries the GitHub API for all repositories owned by `vitorecomp`, updates `link`, `ssh link`, `last updated`, and `is a fork`, preserves `folder`, `is-custom`, and `is-template`, and sorts the CSV by `last updated` descending.

```bash
# Preview changes without modifying repo_stats.csv
python3 workspace/scripts/update_repo_stats.py --dry-run

# Update repo_stats.csv (optionally set GITHUB_TOKEN or METRICS_TOKEN to include private repos)
python3 workspace/scripts/update_repo_stats.py
```

### 3.2 Synchronizing `~/workspace` (`sync_workspace_repos.py`)

Reads `repo_stats.csv` and converges `~/workspace` to match the assigned `folder` mappings:
1. Ignores any CSV row where `folder` is empty, and ignores any local folder/repo in `~/workspace` that is not assigned a `folder` in the CSV.
2. Moves already-cloned repositories in `~/workspace` to `~/workspace/<folder>/<name>` if they are currently in a different category folder.
3. Clones any missing repositories that have a `folder` assigned in the CSV (trying SSH first and automatically falling back to HTTPS).

```bash
# Preview moves and clones without touching the filesystem
python3 workspace/scripts/sync_workspace_repos.py --dry-run

# Synchronize ~/workspace with 4 concurrent clone workers
python3 workspace/scripts/sync_workspace_repos.py --jobs 4
```

### 3.3 Validating Repositories Are Pushed (`validate_repos_pushed.py`)

Scans `~/workspace` (or any specified folder/category) for Git repositories and verifies that each repository has a remote configured, a clean working tree, and no unpushed local commits across its branches.

```bash
# Preview repositories that would be validated
python3 workspace/scripts/validate_repos_pushed.py --dry-run

# Validate all repositories in ~/workspace
python3 workspace/scripts/validate_repos_pushed.py

# Validate a specific category folder under ~/workspace (or an explicit path)
python3 workspace/scripts/validate_repos_pushed.py personal

# Fetch remotes first and ignore untracked files
python3 workspace/scripts/validate_repos_pushed.py --fetch --ignore-untracked
```

### 3.4 Enrolling GitHub Repositories on Taiga (`enroll_taiga_projects.py`)

Reads `repo_stats.csv`, optionally fetches live GitHub descriptions/topics, and idempotently creates corresponding projects on the Taiga server (`https://taiga.vitorx86.dev`) via the Taiga REST API (`/api/v1/projects`).

```bash
# Preview repositories that would be enrolled on Taiga (safe, read-only)
python3 workspace/scripts/enroll_taiga_projects.py --dry-run

# Preview only repositories in a specific workspace category folder (e.g., personal)
python3 workspace/scripts/enroll_taiga_projects.py personal --dry-run

# Enroll all non-fork repositories assigned a folder in repo_stats.csv
TAIGA_ADMIN_PASSWORD=<your_taiga_password> python3 workspace/scripts/enroll_taiga_projects.py

# Enroll only 'personal' folder repositories (or a single repo with --repo)
TAIGA_ADMIN_PASSWORD=<your_taiga_password> python3 workspace/scripts/enroll_taiga_projects.py personal
TAIGA_ADMIN_PASSWORD=<your_taiga_password> python3 workspace/scripts/enroll_taiga_projects.py --repo personal-infra
```
