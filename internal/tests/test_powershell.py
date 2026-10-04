"""The groups of tests still in Invoke-Tests.ps1, for the PowerShell scripts, one group at a time.

Each group moves to pytest when the script it tests moves to Python.
"""

import shutil
import subprocess
import sys

import pytest

from helpers import REPO_ROOT

GROUPS = ["setup", "sync", "shared", "docs"]


@pytest.mark.parametrize("group", GROUPS)
def test_powershell_group(group: str) -> None:
    pwsh = shutil.which("pwsh") or "pwsh"
    script = REPO_ROOT / "internal" / "tests" / "Invoke-Tests.ps1"
    done = subprocess.run(
        [pwsh, "-NoProfile", "-File", str(script), "-Group", group, "-PythonDir", sys.base_prefix],
        cwd=REPO_ROOT,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    failed = [line for line in done.stdout.splitlines() if line.startswith(("FAIL", "      "))]
    assert done.returncode == 0, "\n".join(failed or [done.stdout, done.stderr])
