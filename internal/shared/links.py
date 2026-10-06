"""Links to folders: finding where one points, making one, and removing one without touching what
it points to."""

import os
import sys
from dataclasses import dataclass
from pathlib import Path

from .paths import comparable, without_long_prefix

if sys.platform == "win32":
    import _winapi


@dataclass(frozen=True)
class LinkInfo:
    """What is at a path: a link, with the comparable path it points to, or something else."""

    is_link: bool
    target: str | None


def is_link(path: Path) -> bool:
    return path.is_symlink() or os.path.isjunction(path)


def link_info(path: Path) -> LinkInfo | None:
    """None when nothing is at the path. A link whose target is gone still counts as a link."""
    if is_link(path):
        target = without_long_prefix(str(path.readlink()))
        if not Path(target).is_absolute():
            target = str(path.parent / target)
        return LinkInfo(True, comparable(target))
    if os.path.lexists(path):
        return LinkInfo(False, None)
    return None


def make_folder_link(link: Path, target: Path) -> str:
    """Makes a link to a folder, and returns its kind: a junction on Windows, which needs no
    Developer Mode, and a symbolic link elsewhere, where any user can make one.
    _winapi.CreateJunction is part of Python on Windows, though not documented for general use;
    Python's own tests make junctions with it."""
    link.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == "win32":
        _winapi.CreateJunction(str(target), str(link))
        return "junction"
    link.symlink_to(target, target_is_directory=True)
    return "symlink"


def remove_folder_link(link: Path) -> None:
    """Removes a link to a folder, never anything in what it points to. A recursive delete would
    follow a junction into its target, so it's never used for a link."""
    try:
        link.unlink()
    except OSError:
        # A junction or a symbolic link to a folder, on Windows.
        link.rmdir()
