"""Asking the person at the console a question, only when someone is there to answer."""

import os
import re
import sys
from typing import TextIO

if sys.platform == "win32":
    import ctypes
    import msvcrt


def is_console() -> bool:
    """Whether a person at a real console can see a question and answer it: input comes from a
    console, and output goes to one. Output sent to a file would hide the question, so setup
    would wait for an answer to something nobody sees."""
    return is_console_stream(sys.stdin) and is_console_stream(sys.stdout)


def is_console_stream(stream: TextIO | None) -> bool:
    """On Windows, isatty() is the wrong check: it's true for the NUL input that agents'
    commands get. So this asks Windows for the stream's console mode, which only a console
    has."""
    if stream is None:
        return False
    try:
        fd = stream.fileno()
    except (OSError, ValueError, AttributeError):
        return False
    if sys.platform == "win32":
        try:
            handle = msvcrt.get_osfhandle(fd)
        except OSError:
            return False
        mode = ctypes.c_ulong()
        return bool(ctypes.WinDLL("kernel32").GetConsoleMode(handle, ctypes.byref(mode)))
    return os.isatty(fd)


def ask(question: str, default: str = "") -> str | None:
    """The answer to a question, or default when the answer is blank. None when input ends
    without one."""
    prompt = f"{question} [{default}]: " if default else f"{question}: "
    try:
        answer = input(prompt)
    except EOFError:
        return None
    return answer.strip() or default


def confirm(question: str) -> bool:
    """True only for yes. Input that ends without an answer counts as no."""
    try:
        answer = input(f"{question} [y/N]: ")
    except EOFError:
        return False
    return re.fullmatch(r"\s*(y|yes)\s*", answer, re.IGNORECASE) is not None
