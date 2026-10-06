"""Status lines and message text, in the one format every script prints."""

import os
import sys
from collections.abc import Iterable

# The words a status line can start with. docs/reference/scripts.md and the skills explain them.
STATES = (
    "OK",
    "COMMITTED",
    "PULLED",
    "MERGED",
    "PUSHED",
    "PENDING",
    "OFFLINE",
    "LEFT",
    "STALE",
    "UPDATE",
    "SETTING",
    "TEST",
    "LINKED",
    "REMOVED",
    "WROTE",
    "CREATED",
    "SET",
    "CHANGE",
    "PROBLEM",
)
WARNING_STATES = {"PENDING", "OFFLINE", "STALE", "UPDATE", "SETTING", "CHANGE", "TEST"}

GREEN = "\x1b[32m"
RED = "\x1b[31m"
YELLOW = "\x1b[33m"
CYAN = "\x1b[36m"
RESET = "\x1b[0m"


def use_color() -> bool:
    """Color only when a person is watching the console. Agents run the scripts with their output
    redirected, so they get plain text. NO_COLOR turns color off too."""
    return sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def color(text: str, code: str) -> str:
    return f"{code}{text}{RESET}" if use_color() else text


def status_line(state: str, message: str) -> None:
    """One status line: the word, padded so every message starts in the same column, then the
    message."""
    if state not in STATES:
        raise ValueError(f"No such state: {state}")
    label = f"{state:<9} "
    if use_color():
        if state == "OK":
            code = GREEN
        elif state == "PROBLEM":
            code = RED
        elif state in WARNING_STATES:
            code = YELLOW
        else:
            code = CYAN
        label = f"{code}{label}{RESET}"
    print(label + message, flush=True)


def first_line(lines: Iterable[str]) -> str:
    """The first line with text in it, for quoting a program's message in one line. Git can
    print warning: and hint: lines before the reason it failed, so those count only when
    nothing else has text."""
    texts = [line.strip() for line in lines if line.strip()]
    reasons = [text for text in texts if not text.startswith(("warning:", "hint:"))]
    return (reasons or texts or ["(no message)"])[0]


def describe(error: BaseException) -> str:
    """An error in one line: its kind, then its message, which alone can be empty."""
    return f"{type(error).__name__}: {error}"


def commit_count(count: int) -> str:
    return "1 commit" if count == 1 else f"{count} commits"
