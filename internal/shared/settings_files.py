"""Changing another tool's settings file safely: reading it with how it's saved, showing a change
as a line diff, and writing it with a backup."""

import difflib
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path

from .links import link_info

# Windows refuses to move a file over one that another program has open, such as antivirus
# scanning it for a moment: access denied (5) when it's the file being replaced, and a sharing
# violation (32) when it's the new copy. The move is tried again until this many seconds have
# passed.
REPLACE_WAIT_SECONDS = 3.0
IN_USE_ERRORS = (5, 32)


@dataclass
class SettingsFile:
    """A settings file's text and how it's saved (byte order mark, line breaks), so a rewrite can
    keep both. text is empty when the file doesn't exist yet. reason says why it can't be
    edited."""

    text: str = ""
    bom: bool = False
    newline: str = "\n"
    final_newline: bool = True
    reason: str | None = None


@dataclass
class Plan:
    """A planned change to a settings file: the new text, or why setup won't make it. note says
    anything else the person should know about the change."""

    file: SettingsFile
    new_text: str | None = None
    reason: str | None = None
    note: str = ""


def read_settings_file(path: Path) -> SettingsFile:
    file = SettingsFile()
    if not path.exists() and not path.is_symlink():
        return file
    found = link_info(path)
    if found is not None and found.is_link:
        file.reason = "it is a link, so edit the file it points to instead"
        return file
    if not os.access(path, os.W_OK):
        file.reason = "it is read-only"
        return file
    data = path.read_bytes()
    file.bom = data.startswith(b"\xef\xbb\xbf")
    try:
        file.text = data[3 if file.bom else 0 :].decode("utf-8")
    except UnicodeDecodeError:
        file.reason = "it is not saved as UTF-8"
        return file
    if file.text.count("\r\n") * 2 > file.text.count("\n"):
        file.newline = "\r\n"
    file.final_newline = file.text == "" or file.text.endswith("\n")
    return file


def to_lines(text: str) -> list[str]:
    """A file's text as lines, without the empty one a final line break leaves."""
    lines = re.split(r"\r?\n", text)
    if text == "" or text.endswith("\n"):
        lines.pop()
    return lines


def write_settings_file(path: Path, text: str, *, bom: bool, backup: bool) -> str:
    """Writes the new text to a file next to the original and reads it back, copies the original
    to a dated backup when backup is set, then moves the new file into place in one step, so the
    file is never missing or half written. Returns the backup's path, or "" when it made none."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".dev-home-new")
    encoding = "utf-8-sig" if bom else "utf-8"
    kept: Path | None = None
    replaced = False
    try:
        with temp.open("w", encoding=encoding, newline="") as file:
            file.write(text)
        with temp.open(encoding=encoding, newline="") as file:
            if file.read() != text:
                raise OSError("The new file did not read back the same.")
        if path.exists():
            # Moving a file over a read-only one works on some systems, so check first.
            if not os.access(path, os.W_OK):
                raise PermissionError(f"{path} is read-only.")
            if backup:
                kept = new_backup(path)
        move_into_place(temp, path)
        replaced = True
        return str(kept) if kept else ""
    finally:
        temp.unlink(missing_ok=True)
        # When the original is still in place, a backup of it is only clutter.
        if kept is not None and not replaced:
            kept.unlink(missing_ok=True)


def move_into_place(temp: Path, path: Path) -> None:
    """Moves temp over path in one step. While Windows refuses because another program has one
    of them open, tries again, waiting a little longer each time, for up to
    REPLACE_WAIT_SECONDS."""
    deadline = time.monotonic() + REPLACE_WAIT_SECONDS
    pause = 0.05
    while True:
        try:
            temp.replace(path)
            return
        except OSError as error:
            in_use = getattr(error, "winerror", None) in IN_USE_ERRORS
            if not in_use or time.monotonic() + pause > deadline:
                raise
        time.sleep(pause)
        pause = min(pause * 2, 0.5)


def new_backup(path: Path) -> Path:
    """Copies a file to a dated backup beside it, never over an older backup."""
    data = path.read_bytes()
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(f"{path.name}.bak-{stamp}")
    number = 2
    while True:
        try:
            file = backup.open("xb")
        except FileExistsError:
            backup = path.with_name(f"{path.name}.bak-{stamp}-{number}")
            number += 1
            continue
        # Created just now, so a backup that fails partway is this one's to remove.
        try:
            with file:
                file.write(data)
        except BaseException:
            backup.unlink(missing_ok=True)
            raise
        return backup


def line_diff(old: list[str], new: list[str], context: int = 2) -> list[str]:
    """The lines that differ between two versions of a file, with a little context, each run
    headed by its line number in the new version. The preview comes from this, so it shows what
    the write really changes, however the new text was built."""
    lines: list[tuple[str, str, int]] = []
    matcher = difflib.SequenceMatcher(None, old, new, autojunk=False)
    for tag, old_start, old_end, new_start, new_end in matcher.get_opcodes():
        if tag == "equal":
            for offset in range(new_end - new_start):
                lines.append((" ", new[new_start + offset], new_start + offset + 1))
            continue
        # A removed line is numbered by the new line that comes next.
        lines.extend(("-", old[index], new_start + 1) for index in range(old_start, old_end))
        lines.extend(("+", new[index], index + 1) for index in range(new_start, new_end))
    show = [False] * len(lines)
    for index, (kind, _, _) in enumerate(lines):
        if kind != " ":
            for near in range(max(0, index - context), min(len(lines), index + context + 1)):
                show[near] = True
    diff: list[str] = []
    for index, (kind, text, number) in enumerate(lines):
        if not show[index]:
            continue
        if index == 0 or not show[index - 1]:
            diff.append(f"Line {number}:")
        diff.append(f"{kind} {text}")
    return diff
