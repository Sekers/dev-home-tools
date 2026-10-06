"""Path forms the scripts compare and write: full, comparable, and with forward slashes."""

import os
import re
from pathlib import Path

# What Windows can put before a full path, such as in a junction's target.
LONG_PREFIXES = ("\\\\?\\", "\\??\\")
# The same before a network path, \\server\share, which keeps its two leading backslashes.
LONG_UNC_PREFIXES = ("\\\\?\\UNC\\", "\\??\\UNC\\")


def without_long_prefix(text: str) -> str:
    """A path as people write it, without the \\\\?\\ that Windows can put before one."""
    for prefix in LONG_UNC_PREFIXES:
        if text.upper().startswith(prefix):
            return "\\\\" + text[len(prefix) :]
    for prefix in LONG_PREFIXES:
        if text.startswith(prefix):
            return text[len(prefix) :]
    return text


def comparable(path: str | Path) -> str:
    """A full path with no \\\\?\\ prefix and no trailing slash. Compare two with same_path,
    which ignores case where the file system does."""
    return os.path.abspath(without_long_prefix(str(path))).rstrip("\\/")


def forward(path: str | Path) -> str:
    """The full path with forward slashes, as the skills' commands use it."""
    return comparable(path).replace("\\", "/")


def same_path(first: str | Path, second: str | Path) -> bool:
    return os.path.normcase(comparable(first)) == os.path.normcase(comparable(second))


def is_inside(path: str | Path, folder: str | Path) -> bool:
    """Whether path is folder itself or somewhere in it, not just a path that starts the same
    way, such as C:/dev-home-old for C:/dev-home."""
    full = os.path.normcase(comparable(path))
    root = os.path.normcase(comparable(folder))
    return full == root or full.startswith(root + os.sep)


def resolve_home(path: str, home: Path) -> str:
    """Expands a leading ~ to the profile folder being set up."""
    if re.match(r"~([\\/]|$)", path):
        return str(home / path[1:].lstrip("\\/"))
    return path


def unsafe_reason(path: str) -> str | None:
    """Why a folder can't be written into the skills' commands, or None when it can. Setup writes
    the paths into commands and pre-approvals as they are, unquoted, so they may hold only
    characters that need no quoting in Git Bash or PowerShell."""
    # A root turns into "C:" once its trailing slash is trimmed, and "C:" means the current
    # folder on that drive.
    if re.fullmatch(r"[A-Za-z]:[\\/]*", path):
        return "is the root of a drive"
    if not re.match(r"[A-Za-z]:[\\/]", path):
        return "is not a full path on a drive, such as C:/Users/you/dev-home"
    if re.search(r"[^A-Za-z0-9_.@\\/-]", path[2:]):
        return "has a space or another character that commands would need quoted"
    return None
