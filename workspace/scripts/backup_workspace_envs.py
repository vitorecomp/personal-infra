#!/usr/bin/env python3
"""Backs up `.env` files across a local workspace to an ignored zip archive and/or Bitwarden.

Behavior:
1. Scans `~/workspace` (or `--workspace PATH` / `$WORKSPACE_DIR`, optionally narrowed to
   a category subfolder such as `personal` or `work`) for `.env` and non-template `.env.*`
   files while always recording paths relative to the workspace root (POSIX format).
2. Skips symlinks, `.zip` archives, template/backup suffixes (`.example`, `.sample`,
   `.template`, `.dist`, `.bak`, `.swp`, `.orig`, `.tmp`), and heavy/VCS/cache directories
   while preserving hidden configuration directories such as `.agents/skills/taiga/.env`.
3. Supports two idempotent backup targets (individually or together):
   - `--zip [PATH]`: writes an atomic mode-`0600` zip archive containing each `.env` at its
     workspace-relative path plus `_manifest.json`. Always ensures Git ignores the archive
     (via `workspace/backups/.gitignore` and, for any Git repository, `<git_dir>/info/exclude`),
     and skips rewriting when existing archive member SHA-256 hashes match.
   - `--bitwarden`: syncs each `.env` as a Bitwarden Secure Note (`workspace-env:<rel_path>`)
     in `--bw-folder` (default `workspace-envs`) via the official `bw` CLI using `BW_SESSION`
     in the subprocess environment (never CLI arguments). Updates only changed items and
     optionally prunes deleted local files within the scanned scope (`--prune`).
4. Never prints secret values, `.env` contents, `BW_PASSWORD`, or `BW_SESSION`.
"""

from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any
import zipfile

SCRIPT_PATH = Path(__file__).resolve()
PROJECT_ROOT = SCRIPT_PATH.parent.parent.parent
DEFAULT_ZIP_DIR = PROJECT_ROOT / "workspace" / "backups"
DEFAULT_ZIP_PATH = DEFAULT_ZIP_DIR / "workspace-envs.zip"
DEFAULT_BW_FOLDER = "workspace-envs"
DEFAULT_BW_PREFIX = "workspace-env:"
DEFAULT_BW_BIN = "bw"
MANIFEST_FILENAME = "_manifest.json"
MANIFEST_SCHEMA_VERSION = 1

SKIP_DIRS: frozenset[str] = frozenset(
    {
        ".git",
        ".hg",
        ".svn",
        "node_modules",
        "__pycache__",
        ".venv",
        "venv",
        "env",
        "ENV",
        ".tox",
        ".nox",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        ".cache",
        ".next",
        ".nuxt",
        ".svelte-kit",
        ".turbo",
        ".terraform",
        ".terraform.d",
        "terraform.tfstate.d",
        "dist",
        "build",
        "target",
        "vendor",
        ".gradle",
        ".cargo",
    }
)

EXCLUDED_ENV_SUFFIXES: tuple[str, ...] = (
    ".example",
    ".sample",
    ".template",
    ".dist",
    ".bak",
    ".swp",
    ".orig",
    ".tmp",
)

BW_MANAGED_FIELD_NAMES: frozenset[str] = frozenset(
    {"rel_path", "sha256", "encoding", "git_tracked"}
)


class BitwardenError(RuntimeError):
    """Raised when a Bitwarden CLI operation fails."""


@dataclass(frozen=True)
class EnvFileEntry:
    rel_path: str
    abs_path: Path
    size: int
    sha256: str
    git_tracked: bool
    content: bytes


def default_workspace_dir() -> Path:
    raw = os.environ.get("WORKSPACE_DIR", "").strip()
    if raw:
        return Path(raw).expanduser()
    return Path.home() / "workspace"


def default_bw_folder() -> str:
    return os.environ.get("BW_FOLDER", "").strip() or DEFAULT_BW_FOLDER


def default_bw_prefix() -> str:
    return os.environ.get("BW_ITEM_PREFIX", "") or DEFAULT_BW_PREFIX


def default_bw_bin() -> str:
    return os.environ.get("BW_CLI", "").strip() or DEFAULT_BW_BIN


def compute_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_env_filename(filename: str, exact_only: bool = False) -> bool:
    lower_name = filename.lower()
    if lower_name.endswith(".zip"):
        return False
    if filename == ".env":
        return True
    if exact_only:
        return False
    if filename.startswith(".env.") and len(filename) > 5:
        return not any(lower_name.endswith(sfx) for sfx in EXCLUDED_ENV_SUFFIXES)
    return False


def normalize_scope_prefix(
    workspace_root: Path,
    folder: str | None,
) -> tuple[Path, str | None]:
    """Resolves optional folder filter against `workspace_root` and returns `(scan_root, scope_prefix)`."""
    resolved_workspace = workspace_root.expanduser().resolve()
    if folder is None:
        return resolved_workspace, None

    cleaned = folder.strip()
    if not cleaned or cleaned == ".":
        return resolved_workspace, None

    candidate = Path(cleaned).expanduser()
    if candidate.is_absolute():
        resolved_scan = candidate.resolve()
        if not resolved_scan.is_relative_to(resolved_workspace):
            raise ValueError(
                f"Folder '{folder}' must reside inside workspace '{resolved_workspace}'."
            )
    else:
        if "\\" in cleaned:
            raise ValueError(f"Invalid folder path (backslashes not allowed): '{folder}'")
        parts = [p for p in cleaned.split("/") if p and p != "."]
        if any(p == ".." for p in parts):
            raise ValueError(f"Folder '{folder}' must not contain '..' segments.")
        resolved_scan = (resolved_workspace.joinpath(*parts)).resolve()
        if not resolved_scan.is_relative_to(resolved_workspace):
            raise ValueError(
                f"Folder '{folder}' escapes workspace '{resolved_workspace}'."
            )

    rel = resolved_scan.relative_to(resolved_workspace).as_posix()
    return resolved_scan, (None if rel == "." else rel)


def is_in_scope(rel_path: str, scope_prefix: str | None) -> bool:
    if scope_prefix is None:
        return True
    return rel_path == scope_prefix or rel_path.startswith(f"{scope_prefix}/")


def is_file_git_tracked(file_path: Path) -> bool:
    try:
        res = subprocess.run(
            [
                "git",
                "-C",
                str(file_path.parent),
                "ls-files",
                "--error-unmatch",
                "--",
                file_path.name,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return False
    return res.returncode == 0


def discover_env_files(
    workspace_root: Path,
    scan_root: Path,
    exact_only: bool = False,
    skip_tracked: bool = False,
) -> list[EnvFileEntry]:
    """Recursively discovers `.env` files under `scan_root`, returning entries sorted by `rel_path`."""
    entries: list[EnvFileEntry] = []
    if not scan_root.exists() or not scan_root.is_dir():
        return entries

    def _walk(current: Path) -> None:
        try:
            children = sorted(current.iterdir(), key=lambda p: p.name)
        except OSError as exc:
            print(f"[warn] Skipping unreadable directory {current}: {exc}", file=sys.stderr)
            return

        for child in children:
            if child.is_symlink():
                continue

            if child.is_dir():
                if child.name in SKIP_DIRS:
                    continue
                _walk(child)
                continue

            if not child.is_file():
                continue

            if not is_env_filename(child.name, exact_only=exact_only):
                continue

            try:
                raw = child.read_bytes()
            except OSError as exc:
                print(f"[warn] Skipping unreadable file {child}: {exc}", file=sys.stderr)
                continue

            git_tracked = is_file_git_tracked(child)
            if skip_tracked and git_tracked:
                continue

            rel_path = child.relative_to(workspace_root).as_posix()
            entries.append(
                EnvFileEntry(
                    rel_path=rel_path,
                    abs_path=child,
                    size=len(raw),
                    sha256=compute_sha256(raw),
                    git_tracked=git_tracked,
                    content=raw,
                )
            )

    _walk(scan_root)
    entries.sort(key=lambda item: item.rel_path)
    return entries


def atomic_write_bytes(target_path: Path, data: bytes, mode: int = 0o600) -> None:
    """Atomically writes `data` to `target_path` using a temp file in the same directory."""
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{target_path.name}.",
        suffix=".tmp",
        dir=str(target_path.parent),
    )
    tmp_path = Path(tmp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, target_path)
        os.chmod(target_path, mode)
    except Exception:
        try:
            if tmp_path.exists():
                tmp_path.unlink()
        except OSError:
            pass
        raise


def ensure_backups_dir_gitignore(zip_path: Path) -> None:
    """Ensures `<PROJECT_ROOT>/workspace/backups/.gitignore` contains `*` when writing inside it."""
    resolved_zip = zip_path.expanduser().resolve()
    resolved_backups_dir = DEFAULT_ZIP_DIR.resolve()
    if not resolved_zip.is_relative_to(resolved_backups_dir):
        return

    resolved_backups_dir.mkdir(parents=True, exist_ok=True)
    gitignore_path = resolved_backups_dir / ".gitignore"
    desired = "*\n"
    if not gitignore_path.exists() or gitignore_path.read_text(encoding="utf-8", errors="replace") != desired:
        gitignore_path.write_text(desired, encoding="utf-8")
    os.chmod(gitignore_path, 0o644)


def ensure_zip_gitignored(zip_path: Path) -> None:
    """Guarantees `zip_path` is ignored by Git when located inside any Git working tree."""
    resolved_zip = zip_path.expanduser().resolve()
    zip_parent = resolved_zip.parent
    if not zip_parent.exists():
        return

    try:
        inside_res = subprocess.run(
            ["git", "-C", str(zip_parent), "rev-parse", "--is-inside-work-tree"],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return

    if inside_res.returncode != 0 or inside_res.stdout.strip() != "true":
        return

    top_res = subprocess.run(
        ["git", "-C", str(zip_parent), "rev-parse", "--show-toplevel"],
        check=False,
        capture_output=True,
        text=True,
    )
    if top_res.returncode != 0 or not top_res.stdout.strip():
        return

    repo_top = Path(top_res.stdout.strip()).resolve()
    try:
        rel_zip = resolved_zip.relative_to(repo_top).as_posix()
    except ValueError:
        return

    check_res = subprocess.run(
        ["git", "-C", str(repo_top), "check-ignore", "-q", "--", rel_zip],
        check=False,
        capture_output=True,
        text=True,
    )
    if check_res.returncode == 0:
        return

    exclude_path_res = subprocess.run(
        ["git", "-C", str(repo_top), "rev-parse", "--git-path", "info/exclude"],
        check=False,
        capture_output=True,
        text=True,
    )
    if exclude_path_res.returncode == 0 and exclude_path_res.stdout.strip():
        raw_exclude = Path(exclude_path_res.stdout.strip())
        exclude_path = (
            raw_exclude if raw_exclude.is_absolute() else (repo_top / raw_exclude).resolve()
        )
    else:
        git_dir_res = subprocess.run(
            ["git", "-C", str(zip_parent), "rev-parse", "--git-dir"],
            check=False,
            capture_output=True,
            text=True,
        )
        if git_dir_res.returncode != 0 or not git_dir_res.stdout.strip():
            return
        raw_git_dir = Path(git_dir_res.stdout.strip())
        git_dir = (
            raw_git_dir if raw_git_dir.is_absolute() else (zip_parent / raw_git_dir).resolve()
        )
        exclude_path = git_dir / "info" / "exclude"

    exclude_path.parent.mkdir(parents=True, exist_ok=True)
    existing_text = (
        exclude_path.read_text(encoding="utf-8", errors="replace")
        if exclude_path.exists()
        else ""
    )
    existing_lines = {line.strip() for line in existing_text.splitlines()}
    anchored_pattern = f"/{rel_zip}"

    if anchored_pattern not in existing_lines and rel_zip not in existing_lines:
        new_text = existing_text
        if new_text and not new_text.endswith("\n"):
            new_text += "\n"
        new_text += f"{anchored_pattern}\n"
        exclude_path.write_text(new_text, encoding="utf-8")
        print(f"[ok] Added '{anchored_pattern}' to {exclude_path}")

    recheck = subprocess.run(
        ["git", "-C", str(repo_top), "check-ignore", "-q", "--", rel_zip],
        check=False,
        capture_output=True,
        text=True,
    )
    if recheck.returncode != 0:
        print(
            f"[warn] Git still does not ignore {resolved_zip} (check negations in .gitignore).",
            file=sys.stderr,
        )


def read_zip_sha256_map(zip_path: Path) -> dict[str, str] | None:
    if not zip_path.is_file():
        return None
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            hashes: dict[str, str] = {}
            for info in zf.infolist():
                if info.is_dir() or info.filename == MANIFEST_FILENAME:
                    continue
                hashes[info.filename] = compute_sha256(zf.read(info.filename))
            return hashes
    except (zipfile.BadZipFile, OSError):
        return None


def _zip_date_time(path: Path) -> tuple[int, int, int, int, int, int]:
    try:
        ts = path.stat().st_mtime
        dt = datetime.fromtimestamp(ts, tz=timezone.utc)
        if dt.year < 1980:
            return (1980, 1, 1, 0, 0, 0)
        return (dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
    except OSError:
        return (1980, 1, 1, 0, 0, 0)


def write_zip_backup(
    entries: list[EnvFileEntry],
    zip_path: Path,
    force: bool = False,
    dry_run: bool = False,
) -> int:
    resolved_zip = zip_path.expanduser().resolve()
    desired_hashes = {entry.rel_path: entry.sha256 for entry in entries}
    existing_hashes = read_zip_sha256_map(resolved_zip)

    if dry_run:
        if existing_hashes is not None and existing_hashes == desired_hashes and not force:
            print(
                f"[dry-run] Zip archive already up to date ({len(entries)} file(s)): {resolved_zip}"
            )
        else:
            action = "rewrite" if resolved_zip.exists() else "create"
            print(
                f"[dry-run] Would {action} zip archive ({len(entries)} file(s), mode 0600): {resolved_zip}"
            )
        return 0

    resolved_zip.parent.mkdir(parents=True, exist_ok=True)
    ensure_backups_dir_gitignore(resolved_zip)
    ensure_zip_gitignored(resolved_zip)

    if existing_hashes is not None and existing_hashes == desired_hashes and not force:
        os.chmod(resolved_zip, 0o600)
        print(f"[ok] Zip archive already up to date ({len(entries)} file(s)): {resolved_zip}")
        return 0

    manifest = {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "files": [
            {
                "rel_path": entry.rel_path,
                "sha256": entry.sha256,
                "size": entry.size,
                "git_tracked": entry.git_tracked,
            }
            for entry in entries
        ],
    }
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")

    fd, tmp_name = tempfile.mkstemp(
        prefix=".workspace-envs-",
        suffix=".zip.tmp",
        dir=str(resolved_zip.parent),
    )
    tmp_path = Path(tmp_name)
    try:
        os.fchmod(fd, 0o600)
        os.close(fd)
        with zipfile.ZipFile(tmp_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for entry in entries:
                info = zipfile.ZipInfo(
                    filename=entry.rel_path,
                    date_time=_zip_date_time(entry.abs_path),
                )
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | 0o600) << 16
                zf.writestr(info, entry.content)

            manifest_info = zipfile.ZipInfo(
                filename=MANIFEST_FILENAME,
                date_time=(1980, 1, 1, 0, 0, 0),
            )
            manifest_info.compress_type = zipfile.ZIP_DEFLATED
            manifest_info.external_attr = (stat.S_IFREG | 0o600) << 16
            zf.writestr(manifest_info, manifest_bytes)

        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, resolved_zip)
        os.chmod(resolved_zip, 0o600)
    except Exception:
        try:
            if tmp_path.exists():
                tmp_path.unlink()
        except OSError:
            pass
        raise

    ensure_zip_gitignored(resolved_zip)
    print(f"[ok] Wrote zip archive ({len(entries)} file(s), mode 0600): {resolved_zip}")
    return 0


def resolve_bw_executable(bw_bin: str) -> str | None:
    if "/" in bw_bin or os.sep in bw_bin:
        candidate = Path(bw_bin).expanduser()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
        return None
    return shutil.which(bw_bin)


def run_bw(
    bw_exe: str,
    args: list[str],
    env: dict[str, str],
    stdin_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [bw_exe, *args],
        input=stdin_text,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )


def get_bw_status(bw_exe: str, env: dict[str, str]) -> dict[str, Any]:
    res = run_bw(bw_exe, ["status"], env=env)
    if res.returncode != 0:
        detail = res.stderr.strip() or res.stdout.strip() or f"exit code {res.returncode}"
        raise BitwardenError(f"Failed to query Bitwarden status: {detail}")
    try:
        data = json.loads(res.stdout)
    except json.JSONDecodeError as exc:
        raise BitwardenError(f"Invalid JSON from 'bw status': {exc}") from exc
    if not isinstance(data, dict):
        raise BitwardenError("Unexpected non-object response from 'bw status'.")
    return data


def ensure_bw_session(bw_exe: str, base_env: dict[str, str]) -> dict[str, str]:
    """Ensures an unlocked Bitwarden CLI session via env vars (never `--session` CLI args)."""
    env = base_env.copy()
    status_data = get_bw_status(bw_exe, env)
    status = str(status_data.get("status", "")).lower()

    if status == "unlocked":
        return env

    if status == "unauthenticated":
        raise BitwardenError(
            "Bitwarden CLI is unauthenticated. Run 'bw login' first, then retry."
        )

    if status == "locked":
        if env.get("BW_PASSWORD"):
            unlock_res = run_bw(
                bw_exe,
                ["unlock", "--passwordenv", "BW_PASSWORD", "--raw"],
                env=env,
            )
            token = unlock_res.stdout.strip()
            if unlock_res.returncode != 0 or not token:
                detail = unlock_res.stderr.strip() or f"exit code {unlock_res.returncode}"
                raise BitwardenError(
                    f"Failed to unlock Bitwarden vault with BW_PASSWORD: {detail}"
                )
            env["BW_SESSION"] = token
            return env

        if sys.stdin.isatty():
            unlock_res = subprocess.run(
                [bw_exe, "unlock", "--raw"],
                env=env,
                stdin=None,
                stderr=None,
                stdout=subprocess.PIPE,
                check=False,
                text=True,
            )
            token = (unlock_res.stdout or "").strip()
            if unlock_res.returncode != 0 or not token:
                raise BitwardenError(
                    "Interactive 'bw unlock --raw' did not return a session key."
                )
            env["BW_SESSION"] = token
            return env

        raise BitwardenError(
            "Bitwarden vault is locked. Run 'export BW_SESSION=\"$(bw unlock --raw)\"' "
            "(or set BW_PASSWORD in the environment) and retry."
        )

    raise BitwardenError(f"Unexpected Bitwarden vault status: '{status or 'unknown'}'.")


def sync_bw_vault(bw_exe: str, env: dict[str, str]) -> None:
    res = run_bw(bw_exe, ["sync"], env=env)
    if res.returncode != 0:
        detail = res.stderr.strip() or res.stdout.strip() or f"exit code {res.returncode}"
        raise BitwardenError(f"'bw sync' failed: {detail}")


def bw_list_folders(bw_exe: str, env: dict[str, str]) -> list[dict[str, Any]]:
    res = run_bw(bw_exe, ["list", "folders"], env=env)
    if res.returncode != 0:
        detail = res.stderr.strip() or res.stdout.strip() or f"exit code {res.returncode}"
        raise BitwardenError(f"'bw list folders' failed: {detail}")
    try:
        folders = json.loads(res.stdout)
    except json.JSONDecodeError as exc:
        raise BitwardenError(f"Invalid JSON from 'bw list folders': {exc}") from exc
    if not isinstance(folders, list):
        raise BitwardenError("Unexpected response format from 'bw list folders'.")
    return [f for f in folders if isinstance(f, dict)]


def bw_find_folder_id(folders: list[dict[str, Any]], folder_name: str) -> str | None:
    for folder in folders:
        if folder.get("name") == folder_name and folder.get("id"):
            return str(folder["id"])
    return None


def _encode_bw_payload(payload: dict[str, Any]) -> str:
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return base64.b64encode(raw).decode("ascii")


def bw_create_folder(bw_exe: str, env: dict[str, str], folder_name: str) -> str:
    encoded = _encode_bw_payload({"name": folder_name})
    res = run_bw(bw_exe, ["create", "folder"], env=env, stdin_text=encoded)
    if res.returncode != 0:
        detail = res.stderr.strip() or res.stdout.strip() or f"exit code {res.returncode}"
        raise BitwardenError(f"Failed to create Bitwarden folder '{folder_name}': {detail}")
    try:
        created = json.loads(res.stdout)
    except json.JSONDecodeError as exc:
        raise BitwardenError(f"Invalid JSON from 'bw create folder': {exc}") from exc
    folder_id = created.get("id") if isinstance(created, dict) else None
    if not folder_id:
        raise BitwardenError(f"Bitwarden did not return an id for folder '{folder_name}'.")
    return str(folder_id)


def bw_list_folder_items(
    bw_exe: str,
    env: dict[str, str],
    folder_id: str,
) -> list[dict[str, Any]]:
    res = run_bw(bw_exe, ["list", "items", "--folderid", folder_id], env=env)
    if res.returncode != 0:
        detail = res.stderr.strip() or res.stdout.strip() or f"exit code {res.returncode}"
        raise BitwardenError(f"'bw list items' failed: {detail}")
    try:
        items = json.loads(res.stdout)
    except json.JSONDecodeError as exc:
        raise BitwardenError(f"Invalid JSON from 'bw list items': {exc}") from exc
    if not isinstance(items, list):
        raise BitwardenError("Unexpected response format from 'bw list items'.")
    return [item for item in items if isinstance(item, dict)]


def bw_get_field(item: dict[str, Any], field_name: str) -> str | None:
    fields = item.get("fields")
    if not isinstance(fields, list):
        return None
    for field in fields:
        if isinstance(field, dict) and field.get("name") == field_name:
            val = field.get("value")
            return None if val is None else str(val)
    return None


def bw_extract_item_rel_path(item: dict[str, Any], prefix: str) -> str | None:
    name = item.get("name")
    if not isinstance(name, str) or not name.startswith(prefix):
        return None
    field_rel = bw_get_field(item, "rel_path")
    if field_rel:
        return field_rel
    derived = name[len(prefix) :]
    return derived or None


def encode_env_for_bw(content: bytes) -> tuple[str, str]:
    if b"\x00" not in content:
        try:
            return content.decode("utf-8"), "utf-8"
        except UnicodeDecodeError:
            pass
    return base64.b64encode(content).decode("ascii"), "base64"


def decode_env_from_bw(item: dict[str, Any]) -> bytes:
    notes = item.get("notes")
    notes_str = "" if notes is None else str(notes)
    encoding = (bw_get_field(item, "encoding") or "utf-8").strip().lower()
    if encoding == "base64":
        return base64.b64decode(notes_str.encode("ascii"))
    return notes_str.encode("utf-8")


def build_bw_item_payload(
    entry: EnvFileEntry,
    folder_id: str,
    prefix: str,
    existing_item: dict[str, Any] | None = None,
) -> dict[str, Any]:
    notes_str, encoding = encode_env_for_bw(entry.content)
    managed_fields = [
        {"name": "rel_path", "value": entry.rel_path, "type": 0},
        {"name": "sha256", "value": entry.sha256, "type": 0},
        {"name": "encoding", "value": encoding, "type": 0},
        {
            "name": "git_tracked",
            "value": "true" if entry.git_tracked else "false",
            "type": 0,
        },
    ]

    if existing_item is not None:
        payload = dict(existing_item)
        preserved_fields = [
            f
            for f in (existing_item.get("fields") or [])
            if isinstance(f, dict) and f.get("name") not in BW_MANAGED_FIELD_NAMES
        ]
        payload["type"] = 2
        payload["secureNote"] = existing_item.get("secureNote") or {"type": 0}
        payload["name"] = f"{prefix}{entry.rel_path}"
        payload["folderId"] = folder_id
        payload["notes"] = notes_str
        payload["fields"] = preserved_fields + managed_fields
        return payload

    return {
        "type": 2,
        "secureNote": {"type": 0},
        "name": f"{prefix}{entry.rel_path}",
        "folderId": folder_id,
        "notes": notes_str,
        "fields": managed_fields,
    }


def sync_bitwarden_backup(
    entries: list[EnvFileEntry],
    bw_bin: str,
    bw_folder: str,
    bw_prefix: str,
    scope_prefix: str | None = None,
    no_sync: bool = False,
    prune: bool = False,
    force: bool = False,
    dry_run: bool = False,
) -> int:
    bw_exe = resolve_bw_executable(bw_bin)
    if bw_exe is None:
        if dry_run:
            print(
                f"[dry-run] Bitwarden CLI '{bw_bin}' not found on PATH; "
                f"would sync {len(entries)} file(s) to Bitwarden folder '{bw_folder}' "
                f"(prefix '{bw_prefix}')."
            )
            return 0
        print(
            f"[error] Bitwarden CLI '{bw_bin}' not found on PATH. "
            "Install the Bitwarden CLI or specify --bw-bin.",
            file=sys.stderr,
        )
        return 1

    if dry_run:
        env = os.environ.copy()
        try:
            status_data = get_bw_status(bw_exe, env)
            status = str(status_data.get("status", "")).lower()
        except BitwardenError:
            status = "unavailable"

        if status != "unlocked":
            print(
                f"[dry-run] Bitwarden vault status is '{status}'; "
                f"would sync {len(entries)} file(s) to folder '{bw_folder}' "
                f"(prefix '{bw_prefix}', prune={prune})."
            )
            return 0

        try:
            folders = bw_list_folders(bw_exe, env)
            folder_id = bw_find_folder_id(folders, bw_folder)
            existing_items = (
                bw_list_folder_items(bw_exe, env, folder_id) if folder_id else []
            )
        except BitwardenError as exc:
            print(
                f"[dry-run] Unable to inspect Bitwarden folder '{bw_folder}' ({exc}); "
                f"would sync {len(entries)} file(s)."
            )
            return 0

        existing_by_rel: dict[str, dict[str, Any]] = {}
        for item in existing_items:
            rel_path = bw_extract_item_rel_path(item, bw_prefix)
            if rel_path and rel_path not in existing_by_rel:
                existing_by_rel[rel_path] = item

        if not folder_id:
            print(f"[dry-run] Would create Bitwarden folder '{bw_folder}'.")

        to_create = 0
        to_update = 0
        unchanged = 0
        for entry in entries:
            existing = existing_by_rel.get(entry.rel_path)
            if existing is None:
                to_create += 1
                print(f"[dry-run] Would create Bitwarden note: {bw_prefix}{entry.rel_path}")
            elif not force and bw_get_field(existing, "sha256") == entry.sha256:
                unchanged += 1
                print(f"[dry-run] Unchanged Bitwarden note: {bw_prefix}{entry.rel_path}")
            else:
                to_update += 1
                print(f"[dry-run] Would update Bitwarden note: {bw_prefix}{entry.rel_path}")

        to_prune = 0
        if prune:
            current_rels = {entry.rel_path for entry in entries}
            for rel_path in sorted(existing_by_rel):
                if is_in_scope(rel_path, scope_prefix) and rel_path not in current_rels:
                    to_prune += 1
                    print(f"[dry-run] Would prune Bitwarden note: {bw_prefix}{rel_path}")

        print(
            f"[dry-run] Bitwarden summary: create={to_create}, update={to_update}, "
            f"unchanged={unchanged}, prune={to_prune}"
        )
        return 0

    try:
        env = ensure_bw_session(bw_exe, os.environ.copy())
        if not no_sync:
            sync_bw_vault(bw_exe, env)

        folders = bw_list_folders(bw_exe, env)
        folder_id = bw_find_folder_id(folders, bw_folder)
        if folder_id is None:
            folder_id = bw_create_folder(bw_exe, env, bw_folder)
            print(f"[ok] Created Bitwarden folder '{bw_folder}'")

        existing_items = bw_list_folder_items(bw_exe, env, folder_id)
        existing_by_rel = {}
        for item in existing_items:
            rel_path = bw_extract_item_rel_path(item, bw_prefix)
            if rel_path and rel_path not in existing_by_rel:
                existing_by_rel[rel_path] = item

        created = 0
        updated = 0
        unchanged = 0
        pruned = 0

        for entry in entries:
            existing = existing_by_rel.get(entry.rel_path)
            if existing is not None:
                if not force and bw_get_field(existing, "sha256") == entry.sha256:
                    unchanged += 1
                    continue

                item_id = existing.get("id")
                if not item_id:
                    raise BitwardenError(
                        f"Existing Bitwarden item for '{entry.rel_path}' is missing an id."
                    )
                payload = build_bw_item_payload(
                    entry=entry,
                    folder_id=folder_id,
                    prefix=bw_prefix,
                    existing_item=existing,
                )
                edit_res = run_bw(
                    bw_exe,
                    ["edit", "item", str(item_id)],
                    env=env,
                    stdin_text=_encode_bw_payload(payload),
                )
                if edit_res.returncode != 0:
                    detail = (
                        edit_res.stderr.strip()
                        or edit_res.stdout.strip()
                        or f"exit code {edit_res.returncode}"
                    )
                    raise BitwardenError(
                        f"Failed to update Bitwarden item '{bw_prefix}{entry.rel_path}': {detail}"
                    )
                updated += 1
                print(f"[updated] Bitwarden note: {bw_prefix}{entry.rel_path}")
            else:
                payload = build_bw_item_payload(
                    entry=entry,
                    folder_id=folder_id,
                    prefix=bw_prefix,
                )
                create_res = run_bw(
                    bw_exe,
                    ["create", "item"],
                    env=env,
                    stdin_text=_encode_bw_payload(payload),
                )
                if create_res.returncode != 0:
                    detail = (
                        create_res.stderr.strip()
                        or create_res.stdout.strip()
                        or f"exit code {create_res.returncode}"
                    )
                    raise BitwardenError(
                        f"Failed to create Bitwarden item '{bw_prefix}{entry.rel_path}': {detail}"
                    )
                created += 1
                print(f"[created] Bitwarden note: {bw_prefix}{entry.rel_path}")

        if prune:
            current_rels = {entry.rel_path for entry in entries}
            for rel_path in sorted(existing_by_rel):
                if not is_in_scope(rel_path, scope_prefix) or rel_path in current_rels:
                    continue
                item_id = existing_by_rel[rel_path].get("id")
                if not item_id:
                    continue
                del_res = run_bw(bw_exe, ["delete", "item", str(item_id)], env=env)
                if del_res.returncode != 0:
                    detail = (
                        del_res.stderr.strip()
                        or del_res.stdout.strip()
                        or f"exit code {del_res.returncode}"
                    )
                    raise BitwardenError(
                        f"Failed to prune Bitwarden item '{bw_prefix}{rel_path}': {detail}"
                    )
                pruned += 1
                print(f"[pruned] Bitwarden note: {bw_prefix}{rel_path}")

        print(
            f"[ok] Bitwarden sync complete (folder='{bw_folder}'): "
            f"created={created}, updated={updated}, unchanged={unchanged}, pruned={pruned}"
        )
        return 0
    except BitwardenError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 1


def resolve_zip_option(
    zip_arg: str | None,
    output_arg: Path | None,
) -> tuple[bool, Path | None]:
    if zip_arg is None and output_arg is None:
        return False, None

    if zip_arg and output_arg is not None:
        zip_resolved = Path(zip_arg).expanduser().resolve()
        out_resolved = output_arg.expanduser().resolve()
        if zip_resolved != out_resolved:
            raise ValueError(
                f"Conflicting zip paths provided: --zip '{zip_arg}' vs --output '{output_arg}'."
            )
        return True, out_resolved

    if zip_arg:
        return True, Path(zip_arg).expanduser().resolve()

    if output_arg is not None:
        return True, output_arg.expanduser().resolve()

    return True, DEFAULT_ZIP_PATH.resolve()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Discover workspace .env files and back them up idempotently to a "
            "gitignored zip archive and/or Bitwarden Secure Notes."
        )
    )
    parser.add_argument(
        "folder",
        nargs="?",
        default=None,
        help="Optional category/subfolder under --workspace to scan (e.g., 'personal').",
    )
    parser.add_argument(
        "-f",
        "--folder",
        dest="folder_flag",
        type=str,
        default=None,
        help="Category/subfolder under --workspace to scan (e.g., 'personal').",
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=default_workspace_dir(),
        help="Workspace root directory (default: $WORKSPACE_DIR or ~/workspace).",
    )
    parser.add_argument(
        "--zip",
        nargs="?",
        const="",
        default=None,
        metavar="PATH",
        help=(
            "Write a mode-0600 zip archive (default path: "
            f"{DEFAULT_ZIP_PATH})."
        ),
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        metavar="PATH",
        help="Zip archive output path (alias for --zip PATH; implies --zip).",
    )
    parser.add_argument(
        "--bitwarden",
        action="store_true",
        help="Sync discovered .env files to Bitwarden Secure Notes via the 'bw' CLI.",
    )
    parser.add_argument(
        "--bw-folder",
        type=str,
        default=default_bw_folder(),
        help=f"Bitwarden folder name (default: $BW_FOLDER or '{DEFAULT_BW_FOLDER}').",
    )
    parser.add_argument(
        "--bw-prefix",
        type=str,
        default=default_bw_prefix(),
        help=f"Bitwarden Secure Note name prefix (default: $BW_ITEM_PREFIX or '{DEFAULT_BW_PREFIX}').",
    )
    parser.add_argument(
        "--bw-bin",
        type=str,
        default=default_bw_bin(),
        help=f"Bitwarden CLI binary name or path (default: $BW_CLI or '{DEFAULT_BW_BIN}').",
    )
    parser.add_argument(
        "--no-sync",
        action="store_true",
        help="Skip 'bw sync' before Bitwarden operations.",
    )
    parser.add_argument(
        "--prune",
        action="store_true",
        help=(
            "In --bitwarden mode, delete Bitwarden items in --bw-folder matching "
            "--bw-prefix whose rel_path (within scanned scope) no longer exists locally."
        ),
    )
    parser.add_argument(
        "--exact-only",
        action="store_true",
        help="Match only exact '.env' filenames (exclude '.env.*' variants).",
    )
    parser.add_argument(
        "--skip-tracked",
        action="store_true",
        help="Skip .env files that are tracked in Git.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Rewrite zip archive / Bitwarden items even when SHA-256 hashes are unchanged.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview discovered .env files and planned backup actions without mutating disk or vault.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    try:
        zip_enabled, zip_path = resolve_zip_option(args.zip, args.output)
    except ValueError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 1

    if not args.dry_run and not zip_enabled and not args.bitwarden:
        print(
            "[error] Select at least one backup destination: --zip [PATH] and/or --bitwarden "
            "(or pass --dry-run to preview discovered .env files).",
            file=sys.stderr,
        )
        return 1

    workspace_root = args.workspace.expanduser().resolve()
    selected_folder = args.folder_flag or args.folder
    try:
        scan_root, scope_prefix = normalize_scope_prefix(workspace_root, selected_folder)
    except ValueError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 1

    if not scan_root.exists():
        if args.dry_run:
            print(
                f"[dry-run] Scan directory does not exist: {scan_root}; 0 .env file(s) discovered."
            )
            entries: list[EnvFileEntry] = []
        else:
            print(f"[error] Scan directory not found: {scan_root}", file=sys.stderr)
            return 1
    else:
        entries = discover_env_files(
            workspace_root=workspace_root,
            scan_root=scan_root,
            exact_only=args.exact_only,
            skip_tracked=args.skip_tracked,
        )
        prefix = "[dry-run]" if args.dry_run else "[info]"
        print(f"{prefix} Discovered {len(entries)} .env file(s) under {scan_root}:")
        for entry in entries:
            print(
                f"  - {entry.rel_path} ({entry.size} B, git_tracked={entry.git_tracked})"
            )

    exit_code = 0

    if zip_enabled and zip_path is not None:
        rc = write_zip_backup(
            entries=entries,
            zip_path=zip_path,
            force=args.force,
            dry_run=args.dry_run,
        )
        if rc != 0:
            exit_code = rc

    if args.bitwarden:
        rc = sync_bitwarden_backup(
            entries=entries,
            bw_bin=args.bw_bin,
            bw_folder=args.bw_folder,
            bw_prefix=args.bw_prefix,
            scope_prefix=scope_prefix,
            no_sync=args.no_sync,
            prune=args.prune,
            force=args.force,
            dry_run=args.dry_run,
        )
        if rc != 0:
            exit_code = rc

    if args.dry_run and not zip_enabled and not args.bitwarden:
        print(
            "[dry-run] No backup destination specified; pass --zip [PATH] and/or --bitwarden to write."
        )

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
