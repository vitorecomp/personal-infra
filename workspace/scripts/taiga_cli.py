#!/usr/bin/env python3
"""Wrapper entrypoint delegating to .agents/skills/taiga/scripts/taiga_cli.py."""

from pathlib import Path
import runpy

SKILL_CLI = (
    Path(__file__).resolve().parent.parent.parent
    / ".agents"
    / "skills"
    / "taiga"
    / "scripts"
    / "taiga_cli.py"
)

if __name__ == "__main__":
    runpy.run_path(str(SKILL_CLI), run_name="__main__")
