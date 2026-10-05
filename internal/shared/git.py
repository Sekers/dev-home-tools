"""Runs git."""

import os
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from .programs import find_program

# A command that finds a lock held by another git process is tried again, this many times in all,
# this many seconds apart. A lock file is never deleted: it may belong to a git that is still
# running.
MAX_TRIES = 5
RETRY_SECONDS = 2.0
LOCKED = re.compile(
    r"Unable to create '[^']*\.lock'|cannot lock ref|index\.lock|could not lock config file"
)
GIT_MISSING = "Git was not found in PATH. Install it (see dev-home-tools' README), then try again."


@dataclass(frozen=True)
class GitResult:
    """A finished git command: its exit code, its output as text, its error lines, whether
    another git process still held a lock, and how many tries it took."""

    code: int
    text: str
    err: list[str]
    locked: bool
    tries: int

    @property
    def out(self) -> list[str]:
        return self.text.splitlines()


def run_git(repo: Path, *args: str) -> GitResult:
    """Runs git in a repo, reading its output as UTF-8. Git's messages are in English, so a
    rejected push or a lock can be told apart from other failures. Only git's own environment
    changes, since this runs inside prepare.py's process. When git isn't in PATH, nothing runs:
    a bare "git" could start a program of that name in the current folder."""
    git = find_program("git")
    if git is None:
        return GitResult(127, "", [GIT_MISSING], False, 1)
    tries = 0
    while True:
        tries += 1
        done = subprocess.run(
            [git, "-C", str(repo), *args],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            env=os.environ | {"LC_ALL": "C"},
            check=False,
        )
        err = done.stderr.splitlines()
        locked = done.returncode != 0 and bool(LOCKED.search(done.stderr))
        if not locked or tries >= MAX_TRIES:
            return GitResult(done.returncode, done.stdout, err, locked, tries)
        time.sleep(RETRY_SECONDS)
