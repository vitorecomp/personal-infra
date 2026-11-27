#!/usr/bin/env bash
# Unified virtualenv wrapper entrypoint for `workspace/scripts/backup_workspace_envs.py`
# (default / `--backup`) and `workspace/scripts/restore_workspace_envs.py` (`--restore`).
#
# Creates and activates an isolated, gitignored Python virtual environment at
# `workspace/.venv` (overridable via `WORKSPACE_VENV_DIR` or `--venv-dir`),
# falling back to `--without-pip` when `ensurepip` (`python3-venv`) is absent.
# `--dry-run` and `-h`/`--help` remain 100% read-only and never create or modify the venv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DOMAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_PY_SCRIPT="$SCRIPT_DIR/backup_workspace_envs.py"
RESTORE_PY_SCRIPT="$SCRIPT_DIR/restore_workspace_envs.py"
DEFAULT_VENV_DIR="$WORKSPACE_DOMAIN_DIR/.venv"
REQUIREMENTS_FILE="$WORKSPACE_DOMAIN_DIR/requirements.txt"

VENV_DIR="${WORKSPACE_VENV_DIR:-$DEFAULT_VENV_DIR}"
EXPLICIT_BACKUP=false
EXPLICIT_RESTORE=false
MODE="backup"
REBUILD_VENV=false
DRY_RUN=false
SHOW_HELP=false
FORWARD_ARGS=()

usage() {
  cat <<EOF
Usage: ./workspace/scripts/workspace_envs.sh [--backup | --restore] [wrapper-options] [script-options]

Runs backup_workspace_envs.py (--backup, default) or restore_workspace_envs.py (--restore)
inside an isolated Python virtual environment (default: $DEFAULT_VENV_DIR,
overridable via WORKSPACE_VENV_DIR or --venv-dir).

Mode Options:
  --backup              Back up workspace .env files via backup_workspace_envs.py (default)
  --restore             Restore workspace .env files via restore_workspace_envs.py

Wrapper Options:
  --venv-dir=PATH       Virtual environment directory (default: $DEFAULT_VENV_DIR)
  --venv-dir PATH       Same as --venv-dir=PATH
  --rebuild-venv        Remove and recreate the virtual environment before running
  -h, --help            Show wrapper and script options and exit

Examples:
  ./workspace/scripts/workspace_envs.sh --zip --dry-run
  ./workspace/scripts/workspace_envs.sh --backup --zip --bitwarden
  ./workspace/scripts/workspace_envs.sh --restore --zip --list
  ./workspace/scripts/workspace_envs.sh --restore --zip --dry-run
  ./workspace/scripts/workspace_envs.sh --restore --bitwarden
EOF
}

normalize_venv_dir() {
  local raw="$1"
  case "$raw" in
    "~")
      if [[ -n "${HOME:-}" ]]; then
        raw="$HOME"
      fi
      ;;
    "~/"*)
      if [[ -n "${HOME:-}" ]]; then
        raw="$HOME/${raw#\~/}"
      fi
      ;;
  esac
  if [[ "$raw" != /* ]]; then
    raw="$(pwd)/$raw"
  fi
  while [[ "$raw" != "/" && "$raw" == */ ]]; do
    raw="${raw%/}"
  done
  printf '%s' "$raw"
}

assert_safe_venv_dir() {
  local dir="$1"
  local resolved=""
  local resolved_home=""
  if [[ -z "$dir" || "$dir" == "/" || "$dir" == "." || "$dir" == ".." || "$dir" == */. || "$dir" == */.. ]] || [[ -n "${HOME:-}" && "$dir" == "$HOME" ]]; then
    echo "[error] Refusing unsafe virtual environment path: '$dir'" >&2
    exit 1
  fi
  resolved="$(python3 -c 'import os, sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$dir")"
  if [[ -n "${HOME:-}" ]]; then
    resolved_home="$(python3 -c 'import os, sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$HOME")"
  fi
  if [[ -z "$resolved" || "$resolved" == "/" ]] || [[ -n "${HOME:-}" && ( "$resolved" == "$HOME" || "$resolved" == "$resolved_home" ) ]]; then
    echo "[error] Refusing unsafe virtual environment path: '$dir' (resolves to '$resolved')" >&2
    exit 1
  fi
}

venv_is_ready() {
  [[ -x "$VENV_DIR/bin/python3" && -f "$VENV_DIR/pyvenv.cfg" ]]
}

has_requirements() {
  [[ -f "$REQUIREMENTS_FILE" ]] && grep -Eq '^[[:space:]]*[^#[:space:]]' "$REQUIREMENTS_FILE"
}

compute_sha256() {
  local target="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$target" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$target" | awk '{print $1}'
  else
    python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$target"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      EXPLICIT_BACKUP=true
      MODE="backup"
      shift
      ;;
    --restore)
      EXPLICIT_RESTORE=true
      MODE="restore"
      shift
      ;;
    --venv-dir=*)
      VENV_DIR="${1#*=}"
      if [[ -z "$VENV_DIR" ]]; then
        echo "[error] --venv-dir requires a non-empty path." >&2
        exit 1
      fi
      shift
      ;;
    --venv-dir)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "[error] --venv-dir requires a non-empty path." >&2
        exit 1
      fi
      VENV_DIR="$2"
      shift 2
      ;;
    --rebuild-venv)
      REBUILD_VENV=true
      shift
      ;;
    -h|--help)
      SHOW_HELP=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      FORWARD_ARGS+=("$1")
      shift
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--dry-run" ]]; then
          DRY_RUN=true
        fi
        FORWARD_ARGS+=("$1")
        shift
      done
      break
      ;;
    *)
      FORWARD_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$EXPLICIT_BACKUP" == "true" && "$EXPLICIT_RESTORE" == "true" ]]; then
  echo "[error] Cannot combine --backup and --restore in the same invocation." >&2
  exit 1
fi

if [[ "$MODE" == "restore" ]]; then
  PY_SCRIPT="$RESTORE_PY_SCRIPT"
else
  PY_SCRIPT="$BACKUP_PY_SCRIPT"
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[error] python3 is required on PATH." >&2
  exit 1
fi

VENV_DIR="$(normalize_venv_dir "$VENV_DIR")"

if [[ "$SHOW_HELP" == "true" ]]; then
  HELP_PYTHON="python3"
  if venv_is_ready; then
    HELP_PYTHON="$VENV_DIR/bin/python3"
  fi

  usage
  echo
  if [[ "$EXPLICIT_RESTORE" == "true" ]]; then
    if [[ ! -f "$RESTORE_PY_SCRIPT" ]]; then
      echo "[error] Underlying Python script not found: $RESTORE_PY_SCRIPT" >&2
      exit 1
    fi
    echo "--- restore_workspace_envs.py (--restore) options ---"
    exec "$HELP_PYTHON" "$RESTORE_PY_SCRIPT" --help
  elif [[ "$EXPLICIT_BACKUP" == "true" ]]; then
    if [[ ! -f "$BACKUP_PY_SCRIPT" ]]; then
      echo "[error] Underlying Python script not found: $BACKUP_PY_SCRIPT" >&2
      exit 1
    fi
    echo "--- backup_workspace_envs.py (--backup) options ---"
    exec "$HELP_PYTHON" "$BACKUP_PY_SCRIPT" --help
  else
    if [[ ! -f "$BACKUP_PY_SCRIPT" ]]; then
      echo "[error] Underlying Python script not found: $BACKUP_PY_SCRIPT" >&2
      exit 1
    fi
    if [[ ! -f "$RESTORE_PY_SCRIPT" ]]; then
      echo "[error] Underlying Python script not found: $RESTORE_PY_SCRIPT" >&2
      exit 1
    fi
    echo "--- backup_workspace_envs.py (--backup, default) options ---"
    "$HELP_PYTHON" "$BACKUP_PY_SCRIPT" --help
    echo
    echo "--- restore_workspace_envs.py (--restore) options ---"
    exec "$HELP_PYTHON" "$RESTORE_PY_SCRIPT" --help
  fi
fi

if [[ ! -f "$PY_SCRIPT" ]]; then
  echo "[error] Underlying Python script not found: $PY_SCRIPT" >&2
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  if [[ "$REBUILD_VENV" == "true" ]]; then
    assert_safe_venv_dir "$VENV_DIR"
    echo "[dry-run] Would rebuild Python virtual environment at $VENV_DIR"
  elif ! venv_is_ready; then
    echo "[dry-run] Would initialize Python virtual environment at $VENV_DIR"
  fi

  if has_requirements; then
    req_sha="$(compute_sha256 "$REQUIREMENTS_FILE")"
    stored_sha=""
    if [[ -f "$VENV_DIR/.requirements.sha256" ]]; then
      stored_sha="$(<"$VENV_DIR/.requirements.sha256")"
    fi
    if [[ "$REBUILD_VENV" == "true" ]] || ! venv_is_ready || [[ "$req_sha" != "$stored_sha" ]]; then
      echo "[dry-run] Would install dependencies from $REQUIREMENTS_FILE into $VENV_DIR"
    fi
  fi

  if venv_is_ready; then
    export VIRTUAL_ENV="$VENV_DIR"
    export PATH="$VENV_DIR/bin:$PATH"
    unset PYTHONHOME
    exec "$VENV_DIR/bin/python3" "$PY_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
  fi

  exec python3 "$PY_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
fi

assert_safe_venv_dir "$VENV_DIR"

if [[ "$REBUILD_VENV" == "true" ]] && [[ -e "$VENV_DIR" || -L "$VENV_DIR" ]]; then
  echo "[info] Rebuilding Python virtual environment at $VENV_DIR"
  rm -rf "$VENV_DIR"
fi

if ! venv_is_ready; then
  if [[ -e "$VENV_DIR" || -L "$VENV_DIR" ]]; then
    rm -rf "$VENV_DIR"
  fi
  echo "[info] Initializing Python virtual environment at $VENV_DIR"
  if command -v uv >/dev/null 2>&1; then
    uv venv --quiet "$VENV_DIR"
  elif ! python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
    rm -rf "$VENV_DIR"
    python3 -m venv --without-pip "$VENV_DIR"
  fi
fi

if has_requirements; then
  req_sha="$(compute_sha256 "$REQUIREMENTS_FILE")"
  stored_sha=""
  if [[ -f "$VENV_DIR/.requirements.sha256" ]]; then
    stored_sha="$(<"$VENV_DIR/.requirements.sha256")"
  fi
  if [[ "$req_sha" != "$stored_sha" ]]; then
    echo "[info] Installing dependencies from $REQUIREMENTS_FILE into $VENV_DIR"
    if command -v uv >/dev/null 2>&1; then
      uv pip install --python "$VENV_DIR/bin/python3" -q -r "$REQUIREMENTS_FILE"
    elif [[ -x "$VENV_DIR/bin/pip" ]]; then
      "$VENV_DIR/bin/pip" install -q -r "$REQUIREMENTS_FILE"
    elif "$VENV_DIR/bin/python3" -m pip --version >/dev/null 2>&1; then
      "$VENV_DIR/bin/python3" -m pip install -q -r "$REQUIREMENTS_FILE"
    else
      echo "[error] Cannot install $REQUIREMENTS_FILE: neither 'uv' nor 'pip' is available in $VENV_DIR." >&2
      exit 1
    fi
    printf '%s\n' "$req_sha" > "$VENV_DIR/.requirements.sha256"
  fi
fi

export VIRTUAL_ENV="$VENV_DIR"
export PATH="$VENV_DIR/bin:$PATH"
unset PYTHONHOME

exec "$VENV_DIR/bin/python3" "$PY_SCRIPT" ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
