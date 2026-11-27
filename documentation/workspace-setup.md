# Workspace Management Setup

This document covers the local `~/workspace` orchestration tools located under [`workspace/`](../workspace).

---

## 1. Overview

The `workspace/` domain maintains a single source-of-truth JSON inventory of all `vitorecomp` GitHub repositories ([`workspace/documentation/repo_stats.json`](../workspace/documentation/repo_stats.json)) and automatically organizes and clones repositories into `~/workspace/<folder>/<name>`.

---

## 2. Repository Inventory (`repo_stats.json`)

[`workspace/documentation/repo_stats.json`](../workspace/documentation/repo_stats.json) is a JSON object keyed by repository name and sorted alphabetically (case-insensitively). Stable fields (`link`, `ssh_link`, `is_fork`) sit between the frequently updated `last_updated` field and the manual fields (`folder`, `is_custom`, `is_template`) so Git can auto-merge automated metadata refreshes with local folder edits cleanly:

| Field | Managed By | Description |
| :--- | :--- | :--- |
| `<key>` | Automated (`update_repo_stats.py`) | GitHub repository name (top-level object key, sorted alphabetically). |
| `last_updated` | Automated (`update_repo_stats.py`) | ISO 8601 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`). |
| `link` | Automated (`update_repo_stats.py`) | HTTPS GitHub URL (`https://github.com/vitorecomp/<name>`). |
| `ssh_link` | Automated (`update_repo_stats.py`) | SSH Git URL (`git@github.com:vitorecomp/<name>.git`). |
| `is_fork` | Automated (`update_repo_stats.py`) | `true` or `false`. |
| `folder` | **Manual (User-curated)** | Target category folder under `~/workspace/<folder>/<name>` (e.g., `personal`, `opensource`, `work`, `contribution`, `bench`, `portifolio`, `hackthon`). Empty `folder` entries are ignored by `download_workspace_repos.py`. |
| `is_custom` | **Manual (User-curated)** | Custom boolean flag preserved across automated syncs. |
| `is_template` | **Manual (User-curated)** | Template boolean flag preserved across automated syncs. |

---

## 3. Scripts & Usage

### 3.1 Updating Repository Metadata (`update_repo_stats.py`)

Queries the GitHub API for all repositories owned by `vitorecomp`, updates `last_updated`, `link`, `ssh_link`, and `is_fork`, preserves `folder`, `is_custom`, and `is_template` (never discarding existing entries), and keeps the JSON sorted alphabetically by repository name.

```bash
# Preview changes without modifying repo_stats.json
python3 workspace/scripts/update_repo_stats.py --dry-run

# Update repo_stats.json (optionally set GITHUB_TOKEN or METRICS_TOKEN to include private repos)
python3 workspace/scripts/update_repo_stats.py
```

### 3.2 Synchronizing `~/workspace` (`sync_workspace_repos.py`)

Reads `repo_stats.json` and converges `~/workspace` to match the assigned `folder` mappings:
1. Ignores any JSON entry where `folder` is empty, and ignores any local folder/repo in `~/workspace` that is not assigned a `folder` in the JSON.
2. Moves already-cloned repositories in `~/workspace` to `~/workspace/<folder>/<name>` if they are currently in a different category folder.
3. Clones any missing repositories that have a `folder` assigned in the JSON (trying SSH first and automatically falling back to HTTPS).

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

### 3.4 Scanning for Committed Keys & Secrets (`scan_repo_secrets.py`)

Audits `personal-infra` (or any repository / `~/workspace` folder) across tracked files, staged Git index blobs (`--staged`), unignored working-tree credential files, and full Git commit history (`--history`), and idempotently installs a local Git `pre-commit` hook (`--install-hook`) that blocks commits containing keys or tokens.

```bash
# Audit tracked files and full Git commit history in personal-infra
python3 workspace/scripts/scan_repo_secrets.py --history

# Preview and install the managed .git/hooks/pre-commit secret guard
python3 workspace/scripts/scan_repo_secrets.py --install-hook --dry-run
python3 workspace/scripts/scan_repo_secrets.py --install-hook

# Scan all repositories in a ~/workspace category folder
python3 workspace/scripts/scan_repo_secrets.py personal
```

### 3.5 Enrolling GitHub Repositories on Taiga (`enroll_taiga_projects.py`)

Reads `repo_stats.json`, optionally fetches live GitHub descriptions/topics, and idempotently creates corresponding projects on the Taiga server (`$TAIGA_URL` from gitignored root `.env`) via the Taiga REST API (`/api/v1/projects`).

```bash
# Preview repositories that would be enrolled on Taiga (safe, read-only)
python3 workspace/scripts/enroll_taiga_projects.py --dry-run

# Preview only repositories in a specific workspace category folder (e.g., personal)
python3 workspace/scripts/enroll_taiga_projects.py personal --dry-run

# Enroll all non-fork repositories assigned a folder in repo_stats.json
TAIGA_ADMIN_PASSWORD=<your_taiga_password> python3 workspace/scripts/enroll_taiga_projects.py

# Enroll only 'personal' folder repositories (or a single repo with --repo)
TAIGA_ADMIN_PASSWORD=<your_taiga_password> python3 workspace/scripts/enroll_taiga_projects.py personal
TAIGA_ADMIN_PASSWORD=<your_taiga_password> python3 workspace/scripts/enroll_taiga_projects.py --repo personal-infra
```

### 3.6 Managing Taiga via CLI & Agent Skill (`taiga_cli.py`)

[`workspace/scripts/taiga_cli.py`](../workspace/scripts/taiga_cli.py) (along with the agent skill in [`.agents/skills/taiga/SKILL.md`](../.agents/skills/taiga/SKILL.md) and [`.agents/skills/taiga/scripts/taiga_cli.py`](../.agents/skills/taiga/scripts/taiga_cli.py)) provides CLI subcommands for managing projects, Scrum sprints, user stories, tasks, issues, epics, and wiki pages on `$TAIGA_URL`:

```bash
# List projects in display order or inspect a single project
python3 workspace/scripts/taiga_cli.py projects list
python3 workspace/scripts/taiga_cli.py projects get personal-infra

# Create a Scrum sprint and a user story
python3 workspace/scripts/taiga_cli.py sprints create personal-infra --name "Sprint 1" --start 2026-11-01 --end 2026-11-15
python3 workspace/scripts/taiga_cli.py stories create personal-infra --subject "Add feature" --points 3 --sprint "Sprint 1"
```

### 3.7 Backing Up & Restoring Workspace `.env` Files (`workspace_envs.sh`)

[`workspace/scripts/workspace_envs.sh`](../workspace/scripts/workspace_envs.sh) is the primary CLI entrypoint for backing up (`--backup`, default) and restoring (`--restore`) local environment files across `~/workspace` (overridable via `--workspace PATH` or `WORKSPACE_DIR`).

The wrapper executes the underlying zero-dependency Python 3.10+ scripts ([`backup_workspace_envs.py`](../workspace/scripts/backup_workspace_envs.py) and [`restore_workspace_envs.py`](../workspace/scripts/restore_workspace_envs.py)) inside an isolated, gitignored Python virtual environment at `workspace/.venv`:
- Override the virtual environment location with `WORKSPACE_VENV_DIR` or `--venv-dir PATH` / `--venv-dir=PATH`, or force recreation with `--rebuild-venv`.
- Falls back cleanly to `python3 -m venv --without-pip` when `ensurepip` (`python3-venv`) is unavailable (or uses `uv` if installed) and syncs optional `workspace/requirements.txt` if present.
- Keeps `--dry-run` and `-h` / `--help` completely read-only (never creates or mutates `workspace/.venv` during dry-runs or help output).

#### Discovery Rules (`backup_workspace_envs.py`)
- Recursively scans `~/workspace` (or an optional category `folder` such as `personal` or `work`, while always recording paths relative to the workspace root like `personal/personal-infra/.env`).
- Captures `.env` and non-template `.env.*` files—including hidden configuration paths such as `.agents/skills/taiga/.env`—while automatically skipping:
  - Template and temporary suffixes (`.example`, `.sample`, `.template`, `.dist`, `.bak`, `.swp`, `.orig`, `.tmp`).
  - Heavy VCS, dependency, build, and cache directories (`.git`, `node_modules`, `.venv`, `venv`, `.terraform`, `dist`, `build`, `__pycache__`, etc.), symlinks, and `.zip` archives.
- Optional filters: `--exact-only` (match only exact `.env` filenames) and `--skip-tracked` (exclude files tracked by Git).

#### Backup Targets (`--zip` & `--bitwarden`)
- **Zip Archive (`--zip [PATH]` / `--output PATH`)**:
  - Defaults to `workspace/backups/workspace-envs.zip` written atomically with mode `0600` (`rw-------`).
  - Always Git-ignored: `.gitignore` ignores `*.zip` and `workspace/backups/` (paired with `workspace/backups/.gitignore` and `scan_repo_secrets.py` archive globs), and if `--zip` targets a path inside another Git repository, `backup_workspace_envs.py` automatically appends the relative archive path to that repository's `.git/info/exclude` if it is not already ignored.
  - Embeds a deterministic `_manifest.json` index (with `rel_path`, `sha256`, `size`, and `git_tracked`) and idempotently skips rewriting the zip when all member SHA-256 hashes match (unless `--force` is set).
- **Bitwarden Vault (`--bitwarden`)**:
  - Uses the official Bitwarden CLI (`bw`, or `--bw-bin` / `BW_CLI`) authenticated via `BW_SESSION` (or `BW_PASSWORD` / interactive `bw unlock --raw`).
  - Runs `bw sync` (unless `--no-sync` is passed) and stores each file idempotently as a Secure Note named `workspace-env:<rel_path>` (prefix configurable via `--bw-prefix` / `BW_ITEM_PREFIX`) inside folder `workspace-envs` (configurable via `--bw-folder` / `BW_FOLDER`), carrying `rel_path`, `sha256`, `encoding`, and `git_tracked` custom fields.
  - Compares `sha256` digests so unchanged items require zero edits; creates missing notes, updates modified notes, and optionally deletes orphaned notes in `--bw-folder` with `--prune`.

#### Safe Idempotent Restoration (`restore_workspace_envs.py`)
- Restores `.env` files from `--zip [PATH]` (or `--input PATH`) or `--bitwarden` back to `~/workspace/<rel_path>` (optionally filtered by category `folder` or `--folder`), writing files atomically with mode `0600` (`rw-------`).
- Rejects path traversal (`ZipSlip`: absolute paths, `..` components, `_manifest.json`, and symlinked parents or targets).
- Leaves matching local files untouched (`unchanged`) and safely skips differing local files unless `--overwrite` (alias `--force`) is passed; combine with `--backup-existing` to copy replaced local files to `<file>.bak` (`0600`).
- Supports `--list` (inspect archive or vault entries without writing files), `--existing-dirs-only` (only restore into directories that already exist locally, skipping uncloned repos), and `--dry-run`.

```bash
# Show wrapper options and underlying Python script flags (all, backup-only, or restore-only)
./workspace/scripts/workspace_envs.sh --help
./workspace/scripts/workspace_envs.sh --backup --help
./workspace/scripts/workspace_envs.sh --restore --help

# Preview discovered .env files and planned backup actions (read-only; does not create workspace/.venv)
./workspace/scripts/workspace_envs.sh --zip --dry-run
./workspace/scripts/workspace_envs.sh --backup --bitwarden --dry-run

# Back up all workspace .env files to the default gitignored zip and Bitwarden Secure Notes
./workspace/scripts/workspace_envs.sh --zip --bitwarden

# Back up only a single workspace category folder to a custom zip path
./workspace/scripts/workspace_envs.sh personal --zip ~/backups/personal-envs.zip

# List entries available in the zip archive or Bitwarden folder
./workspace/scripts/workspace_envs.sh --restore --zip --list
./workspace/scripts/workspace_envs.sh --restore --bitwarden --list

# Preview and execute restoration (creates missing directories by default; skips differing files)
./workspace/scripts/workspace_envs.sh --restore --zip --dry-run
./workspace/scripts/workspace_envs.sh --restore --bitwarden --dry-run
./workspace/scripts/workspace_envs.sh --restore --zip --existing-dirs-only
./workspace/scripts/workspace_envs.sh --restore --bitwarden personal --overwrite --backup-existing

# Direct Python invocation (without the virtualenv wrapper) is also supported:
# python3 workspace/scripts/backup_workspace_envs.py --zip --dry-run
# python3 workspace/scripts/restore_workspace_envs.py --zip --dry-run
```
