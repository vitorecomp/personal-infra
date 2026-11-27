#!/usr/bin/env python3
r"""Restores `.env` files into their exact workspace folders from a zip archive or Bitwarden.

Behavior:
1. Reads `.env` entries from either `--zip [PATH]` (or `--input PATH`) or `--bitwarden`
   (Bitwarden Secure Notes in `--bw-folder` matching `--bw-prefix` / `rel_path`).
2. Strictly validates every entry path before touching disk: rejects empty paths,
   absolute paths, leading `/` or `\`, backslashes, Windows drive letters, `_manifest.json`,
   `..` traversal segments (`ZipSlip`), archive symlinks, and symlinked destination parent
   directories or target files.
3. Restores files atomically to `<workspace>/<rel_path>` with mode `0600` (`rw-------`):
   - Identical existing files (matching SHA-256) are left untouched (`unchanged`).
   - Differing existing files are safely preserved (`skipped`) unless `--overwrite`
     (alias `--force`) is passed; optional `--backup-existing` first saves `<file>.bak`
     (mode `0600`).
   - Optional `--existing-dirs-only` skips entries whose parent directory does not yet
     exist locally.
   - Optional category `folder` / `--folder` restricts restoration to `<folder>/...`.
   - `--list` prints available entries (`rel_path`, size, short SHA-256) without writing.
4. Never prints secret values, `.env` contents, `BW_PASSWORD`, or `BW_SESSION`.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path, PurePosixPath, PureWindowsPath
import stat
import sys
import zipfile

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from backup_workspace_envs import (
    BitwardenError,
    DEFAULT_BW_BIN,
    DEFAULT_BW_FOLDER,
    DEFAULT_BW_PREFIX,
    DEFAULT_ZIP_PATH,
    MANIFEST_FILENAME,
    atomic_write_bytes,
    bw_extract_item_rel_path,
    bw_find_folder_id,
    bw_list_folder_items,
    bw_list_folders,
    compute_sha256,
    decode_env_from_bw,
    default_bw_bin,
    default_bw_folder,
    default_bw_prefix,
    default_workspace_dir,
    ensure_bw_session,
    get_bw_status,
    is_in_scope,
    normalize_scope_prefix,
    resolve_bw_executable,
    sync_bw_vault,
)


class UnsafePathError(ValueError):
    """Raised when a backup entry path violates containment or symlink safety checks."""


@dataclass(frozen=True)
class BackupEntry:
    rel_path: str
    content: bytes
    sha256: str
    size: int


def validate_rel_path(rel_path: str) -> tuple[str, ...]:
    """Strictly validates a POSIX workspace-relative path and returns its path segments."""
    if not isinstance(rel_path, str) or not rel_path:
        raise UnsafePathError("Empty archive/vault path is not allowed.")

    if "\x00" in rel_path:
        raise UnsafePathError(f"NUL byte disallowed in path: {rel_path!r}")

    if rel_path.startswith(("/", "\\")):
        raise UnsafePathError(f"Absolute or root-prefixed path disallowed: {rel_path!r}")

    if "\\" in rel_path:
        raise UnsafePathError(f"Backslashes disallowed in path: {rel_path!r}")

    if PurePosixPath(rel_path).is_absolute():
        raise UnsafePathError(f"Absolute POSIX path disallowed: {rel_path!r}")

    if (len(rel_path) >= 2 and rel_path[1] == ":") or PureWindowsPath(rel_path).drive:
        raise UnsafePathError(f"Drive-letter path disallowed: {rel_path!r}")

    if rel_path == MANIFEST_FILENAME:
        raise UnsafePathError(f"Manifest path '{MANIFEST_FILENAME}' cannot be restored.")

    parts = rel_path.split("/")
    for part in parts:
        if part in {"", ".", ".."}:
            raise UnsafePathError(f"Invalid or traversal path segment in: {rel_path!r}")
        if ":" in part and len(part) >= 2 and part[1] == ":":
            raise UnsafePathError(f"Drive-like segment disallowed in path: {rel_path!r}")

    if parts[-1] == MANIFEST_FILENAME:
        raise UnsafePathError(f"Manifest filename '{MANIFEST_FILENAME}' cannot be restored.")

    return tuple(parts)


def resolve_safe_target(workspace_root: Path, rel_path: str) -> Path:
    """Resolves `rel_path` under `workspace_root` while rejecting escapes and symlinks."""
    parts = validate_rel_path(rel_path)
    resolved_root = workspace_root.expanduser().resolve()

    if workspace_root.expanduser().is_symlink():
        # Resolved root itself is already dereferenced; disallow symlinks strictly inside it.
        pass

    current = resolved_root
    for part in parts[:-1]:
        current = current / part
        if current.is_symlink():
            raise UnsafePathError(
                f"Symlinked parent directory disallowed for '{rel_path}': {current}"
            )
        if current.exists() and not current.is_dir():
            raise UnsafePathError(
                f"Parent path exists and is not a directory for '{rel_path}': {current}"
            )

    target = current / parts[-1]
    if target.is_symlink():
        raise UnsafePathError(f"Symlinked target file disallowed for '{rel_path}': {target}")
    if target.exists() and target.is_dir():
        raise UnsafePathError(
            f"Target path exists and is a directory for '{rel_path}': {target}"
        )

    resolved_target = target.resolve()
    if resolved_target == resolved_root or not resolved_target.is_relative_to(resolved_root):
        raise UnsafePathError(
            f"Resolved path escapes workspace root '{resolved_root}': '{rel_path}'"
        )

    return target


def load_entries_from_zip(zip_path: Path) -> list[BackupEntry]:
    entries: list[BackupEntry] = []
    seen: set[str] = set()

    with zipfile.ZipFile(zip_path, "r") as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            if info.filename == MANIFEST_FILENAME:
                continue

            mode_bits = info.external_attr >> 16
            if stat.S_ISLNK(mode_bits):
                raise UnsafePathError(
                    f"Symlink archive entry disallowed: {info.filename!r}"
                )

            validate_rel_path(info.filename)
            if info.filename in seen:
                raise UnsafePathError(
                    f"Duplicate archive entry detected: {info.filename!r}"
                )
            seen.add(info.filename)

            raw = zf.read(info.filename)
            entries.append(
                BackupEntry(
                    rel_path=info.filename,
                    content=raw,
                    sha256=compute_sha256(raw),
                    size=len(raw),
                )
            )

    entries.sort(key=lambda item: item.rel_path)
    return entries


def load_entries_from_bitwarden(
    bw_bin: str,
    bw_folder: str,
    bw_prefix: str,
    no_sync: bool = False,
    dry_run: bool = False,
) -> tuple[list[BackupEntry] | None, int]:
    """Loads `.env` entries from Bitwarden. Returns `(entries, exit_code)` where `entries=None` means handled early."""
    bw_exe = resolve_bw_executable(bw_bin)
    if bw_exe is None:
        if dry_run:
            print(
                f"[dry-run] Bitwarden CLI '{bw_bin}' not found on PATH; "
                f"unable to query folder '{bw_folder}'."
            )
            return None, 0
        print(
            f"[error] Bitwarden CLI '{bw_bin}' not found on PATH. "
            "Install the Bitwarden CLI or specify --bw-bin.",
            file=sys.stderr,
        )
        return None, 1

    try:
        if dry_run:
            env = os.environ.copy()
            status_data = get_bw_status(bw_exe, env)
            status = str(status_data.get("status", "")).lower()
            if status != "unlocked":
                print(
                    f"[dry-run] Bitwarden vault status is '{status}' "
                    f"(set BW_SESSION to preview live items from folder '{bw_folder}'); "
                    "no files written."
                )
                return None, 0
        else:
            env = ensure_bw_session(bw_exe, os.environ.copy())
            if not no_sync:
                sync_bw_vault(bw_exe, env)

        folders = bw_list_folders(bw_exe, env)
        folder_id = bw_find_folder_id(folders, bw_folder)
        if folder_id is None:
            if dry_run:
                print(
                    f"[dry-run] Bitwarden folder '{bw_folder}' not found; 0 file(s) to restore."
                )
                return None, 0
            print(f"[error] Bitwarden folder '{bw_folder}' not found.", file=sys.stderr)
            return None, 1

        items = bw_list_folder_items(bw_exe, env, folder_id)
    except BitwardenError as exc:
        if dry_run:
            print(
                f"[dry-run] Unable to query Bitwarden folder '{bw_folder}' ({exc}); "
                "no files written."
            )
            return None, 0
        print(f"[error] {exc}", file=sys.stderr)
        return None, 1

    entries: list[BackupEntry] = []
    seen: set[str] = set()
    for item in items:
        rel_path = bw_extract_item_rel_path(item, bw_prefix)
        if rel_path is None:
            continue

        validate_rel_path(rel_path)
        if rel_path in seen:
            print(
                f"[warn] Duplicate Bitwarden item for '{rel_path}'; keeping first entry.",
                file=sys.stderr,
            )
            continue
        seen.add(rel_path)

        try:
            raw = decode_env_from_bw(item)
        except Exception as exc:
            print(
                f"[error] Failed to decode Bitwarden item for '{rel_path}': {exc}",
                file=sys.stderr,
            )
            return None, 1

        entries.append(
            BackupEntry(
                rel_path=rel_path,
                content=raw,
                sha256=compute_sha256(raw),
                size=len(raw),
            )
        )

    entries.sort(key=lambda item: item.rel_path)
    return entries, 0


def resolve_restore_source(
    zip_arg: str | None,
    input_arg: Path | None,
    bitwarden: bool,
    dry_run: bool,
) -> tuple[str, Path | None]:
    """Returns `('zip', zip_path)` or `('bitwarden', None)` after validating source flags."""
    zip_requested = zip_arg is not None or input_arg is not None
    if zip_requested and bitwarden:
        raise ValueError("Choose exactly one restore source: --zip/--input OR --bitwarden.")

    if bitwarden:
        return "bitwarden", None

    if not zip_requested:
        if dry_run:
            return "zip", DEFAULT_ZIP_PATH.resolve()
        raise ValueError(
            "Specify a restore source: --zip [PATH] (or --input PATH) or --bitwarden."
        )

    if zip_arg and input_arg is not None:
        zip_resolved = Path(zip_arg).expanduser().resolve()
        in_resolved = input_arg.expanduser().resolve()
        if zip_resolved != in_resolved:
            raise ValueError(
                f"Conflicting zip paths provided: --zip '{zip_arg}' vs --input '{input_arg}'."
            )
        return "zip", in_resolved

    if zip_arg:
        return "zip", Path(zip_arg).expanduser().resolve()

    if input_arg is not None:
        return "zip", input_arg.expanduser().resolve()

    return "zip", DEFAULT_ZIP_PATH.resolve()


def restore_entries(
    entries: list[BackupEntry],
    workspace_root: Path,
    overwrite: bool = False,
    backup_existing: bool = False,
    existing_dirs_only: bool = False,
    dry_run: bool = False,
) -> int:
    # Validate all destination paths and symlink safety before mutating disk.
    planned: list[tuple[BackupEntry, Path]] = []
    for entry in entries:
        target = resolve_safe_target(workspace_root, entry.rel_path)
        planned.append((entry, target))

    restored = 0
    overwritten = 0
    unchanged = 0
    skipped = 0

    for entry, target in planned:
        if target.exists():
            existing_bytes = target.read_bytes()
            if compute_sha256(existing_bytes) == entry.sha256:
                unchanged += 1
                tag = "[dry-run] Unchanged" if dry_run else "[unchanged]"
                print(f"{tag} {entry.rel_path}")
                continue

            if not overwrite:
                skipped += 1
                if dry_run:
                    print(
                        f"[dry-run] Would skip {entry.rel_path} "
                        "(exists and differs; pass --overwrite to replace)"
                    )
                else:
                    print(
                        f"[skipped] {entry.rel_path} "
                        "(exists and differs; pass --overwrite to replace)"
                    )
                continue

            bak_path = target.parent / f"{target.name}.bak"
            if backup_existing and bak_path.is_symlink():
                raise UnsafePathError(
                    f"Symlinked backup file disallowed for '{entry.rel_path}': {bak_path}"
                )

            overwritten += 1
            if dry_run:
                bak_note = (
                    f" (would back up existing to {bak_path.name})"
                    if backup_existing
                    else ""
                )
                print(f"[dry-run] Would overwrite {entry.rel_path}{bak_note}")
            else:
                if backup_existing:
                    atomic_write_bytes(bak_path, existing_bytes, mode=0o600)
                atomic_write_bytes(target, entry.content, mode=0o600)
                bak_note = (
                    f" (backup saved to {bak_path.name})" if backup_existing else ""
                )
                print(f"[overwritten] {entry.rel_path}{bak_note}")
            continue

        if existing_dirs_only and not target.parent.exists():
            skipped += 1
            if dry_run:
                print(
                    f"[dry-run] Would skip {entry.rel_path} "
                    "(parent directory does not exist; --existing-dirs-only)"
                )
            else:
                print(
                    f"[skipped] {entry.rel_path} "
                    "(parent directory does not exist; --existing-dirs-only)"
                )
            continue

        restored += 1
        if dry_run:
            print(f"[dry-run] Would restore {entry.rel_path}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.is_symlink():
                raise UnsafePathError(
                    f"Symlinked target file appeared before write: {target}"
                )
            atomic_write_bytes(target, entry.content, mode=0o600)
            print(f"[restored] {entry.rel_path}")

    prefix = "[dry-run] " if dry_run else ""
    print(
        f"\n{prefix}Summary: restored={restored}, overwritten={overwritten}, "
        f"unchanged={unchanged}, skipped={skipped}"
    )
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Restore workspace .env files from a zip archive or Bitwarden Secure Notes "
            "back into their exact relative folders with mode 0600 permissions."
        )
    )
    parser.add_argument(
        "folder",
        nargs="?",
        default=None,
        help="Optional category/subfolder filter (e.g., 'personal') to restore only '<folder>/...'.",
    )
    parser.add_argument(
        "-f",
        "--folder",
        dest="folder_flag",
        type=str,
        default=None,
        help="Category/subfolder filter (e.g., 'personal') to restore only '<folder>/...'.",
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=default_workspace_dir(),
        help="Destination workspace root directory (default: $WORKSPACE_DIR or ~/workspace).",
    )
    parser.add_argument(
        "--zip",
        nargs="?",
        const="",
        default=None,
        metavar="PATH",
        help=(
            "Restore from a zip archive (default path: "
            f"{DEFAULT_ZIP_PATH})."
        ),
    )
    parser.add_argument(
        "-i",
        "--input",
        type=Path,
        default=None,
        metavar="PATH",
        help="Zip archive input path (alias for --zip PATH; implies --zip).",
    )
    parser.add_argument(
        "--bitwarden",
        action="store_true",
        help="Restore from Bitwarden Secure Notes in --bw-folder.",
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
        help="Skip 'bw sync' before reading from Bitwarden.",
    )
    parser.add_argument(
        "--overwrite",
        "--force",
        dest="overwrite",
        action="store_true",
        help="Overwrite existing local .env files whose content differs from the backup.",
    )
    parser.add_argument(
        "--backup-existing",
        action="store_true",
        help="When --overwrite replaces a differing local file, first copy it to <file>.bak (mode 0600).",
    )
    parser.add_argument(
        "--existing-dirs-only",
        action="store_true",
        help="Only restore .env files whose parent directory already exists locally.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List backup entries (rel_path, size, short SHA-256) without writing any files.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview restored/overwritten/unchanged/skipped actions without modifying disk.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    try:
        source_kind, zip_path = resolve_restore_source(
            zip_arg=args.zip,
            input_arg=args.input,
            bitwarden=args.bitwarden,
            dry_run=args.dry_run,
        )
    except ValueError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 1

    workspace_root = args.workspace.expanduser().resolve()
    selected_folder = args.folder_flag or args.folder
    try:
        _, scope_prefix = normalize_scope_prefix(workspace_root, selected_folder)
    except ValueError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 1

    try:
        if source_kind == "zip":
            assert zip_path is not None
            if not zip_path.exists():
                if args.dry_run:
                    print(
                        f"[dry-run] Zip archive does not exist yet: {zip_path}; "
                        "0 file(s) to restore."
                    )
                    return 0
                print(f"[error] Zip archive not found: {zip_path}", file=sys.stderr)
                return 1
            source_label = str(zip_path)
            entries = load_entries_from_zip(zip_path)
        else:
            source_label = f"Bitwarden folder '{args.bw_folder}'"
            loaded, rc = load_entries_from_bitwarden(
                bw_bin=args.bw_bin,
                bw_folder=args.bw_folder,
                bw_prefix=args.bw_prefix,
                no_sync=args.no_sync,
                dry_run=args.dry_run,
            )
            if loaded is None:
                return rc
            entries = loaded
    except UnsafePathError as exc:
        print(f"[error] Security check failed: {exc}", file=sys.stderr)
        return 1
    except (zipfile.BadZipFile, OSError) as exc:
        print(f"[error] Failed to read zip archive: {exc}", file=sys.stderr)
        return 1

    if scope_prefix is not None:
        entries = [entry for entry in entries if is_in_scope(entry.rel_path, scope_prefix)]

    if args.list:
        print(f"Entries in {source_label} ({len(entries)} file(s)):")
        for entry in entries:
            print(f"  - {entry.rel_path} ({entry.size} B, sha256={entry.sha256[:12]})")
        return 0

    try:
        return restore_entries(
            entries=entries,
            workspace_root=workspace_root,
            overwrite=args.overwrite,
            backup_existing=args.backup_existing,
            existing_dirs_only=args.existing_dirs_only,
            dry_run=args.dry_run,
        )
    except UnsafePathError as exc:
        print(f"[error] Security check failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
