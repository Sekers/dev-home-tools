"""What every test gets: in this process, the environment the sandboxes' scripts run in, and when
a worker's tests are done, a check that the real profile has nothing pointing into a sandbox."""

import json
import os
import tomllib
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import pytest

from helpers import SANDBOX_ROOT, link_target


@pytest.fixture(autouse=True)
def scripts_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """Some tests run the scripts' code in this process, so it gets what script_env gives the
    scripts' own processes: git stops looking for a repo at the sandboxes, and the session
    running the tests can't hand its own Claude folder to setup."""
    monkeypatch.setenv("GIT_CEILING_DIRECTORIES", SANDBOX_ROOT.as_posix())
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_ENTRYPOINT", raising=False)


@pytest.fixture(scope="session", autouse=True)
def real_profile_untouched() -> Iterator[None]:
    """The point of the sandboxes. Each worker checks after its own tests, so every test that
    ran setup's code, in a process of its own or in this one, comes before a check."""
    yield
    hits = into_sandboxes(Path.home())
    assert hits == [], "The real profile points into a test sandbox:\n" + "\n".join(hits)


def into_sandboxes(home: Path) -> list[str]:
    """What in the profile points into a sandbox: links to skills and rules, the folders Claude
    Code and Codex may use, and Codex's always-on rules."""
    sandboxes = str(SANDBOX_ROOT.resolve()).replace("\\", "/").lower()

    def inside(text: str) -> bool:
        return sandboxes in text.replace("\\\\", "/").replace("\\", "/").lower()

    claude_dirs = [folder for folder in home.glob(".claude*") if folder.is_dir()]
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        claude_dirs.append(Path(os.environ["CLAUDE_CONFIG_DIR"]).expanduser())
    link_folders = [home / ".agents" / "skills"]
    for claude in claude_dirs:
        link_folders += [claude / "skills", claude / "rules"]

    hits: list[str] = []
    for folder in link_folders:
        if not folder.is_dir():
            continue
        for entry in folder.iterdir():
            target = link_target(entry)
            if target is not None and inside(str(target)):
                hits.append(f"{entry} -> {target}")
    for claude in claude_dirs:
        settings = claude / "settings.json"
        allowed = setting(json.loads, settings, "permissions", "additionalDirectories")
        if any(isinstance(folder, str) and inside(folder) for folder in allowed):
            hits.append(str(settings))
    config = home / ".codex" / "config.toml"
    roots = setting(tomllib.loads, config, "sandbox_workspace_write", "writable_roots")
    if any(isinstance(root, str) and inside(root) for root in roots):
        hits.append(str(config))
    rules = home / ".codex" / "AGENTS.md"
    if rules.is_file() and inside(read(rules)):
        hits.append(str(rules))
    return hits


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig", errors="replace")


def setting(parse: Callable[[str], Any], path: Path, table: str, key: str) -> list[Any]:
    """A list two levels down in a settings file, or an empty one when anything is missing."""
    try:
        value = parse(read(path))[table][key]
    except (OSError, ValueError, KeyError, TypeError):
        return []
    return value if isinstance(value, list) else []
