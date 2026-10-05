"""Finds the programs the scripts start, and runs setup.ps1, which is still PowerShell."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

from .output import status_line
from .settings import TOOLS_ROOT


def find_program(name: str) -> str | None:
    """A program's full path, from the folders in PATH. On Windows, a search would look in the
    current folder first, which may be a project's: a program of the same name there must never
    run, so only full paths in PATH count."""
    if sys.platform != "win32":
        return shutil.which(name)
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        if folder and Path(folder).is_absolute():
            candidate = Path(folder) / f"{name}.exe"
            if candidate.is_file():
                return str(candidate)
    return None


def run_setup() -> bool:
    """Runs setup.ps1 -Quiet in a PowerShell process of its own, which prints its own lines,
    PROBLEM lines included, straight to this script's output. Returns whether it ran and had no
    problem."""
    pwsh = find_program("pwsh")
    if pwsh is None:
        status_line(
            "PROBLEM",
            "PowerShell 7 (pwsh) was not found, so setup did not run. "
            "Install it (see dev-home-tools' README), then try again.",
        )
        return False
    # Setup writes to the same output, so this script's lines go out first.
    sys.stdout.flush()
    done = subprocess.run(
        [pwsh, "-NoProfile", "-File", str(TOOLS_ROOT / "setup.ps1"), "-Quiet"],
        stdin=subprocess.DEVNULL,
        check=False,
    )
    return done.returncode == 0


def by_hand(script: str) -> str:
    """The command a person types to run one of the scripts in the root."""
    launcher = "py" if sys.platform == "win32" else "python3"
    return f"{launcher} {(TOOLS_ROOT / script).as_posix()}"
