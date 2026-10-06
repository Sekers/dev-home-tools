"""This PC's settings, from local-settings.json in dev-home-tools' folder. setup.py writes it."""

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# dev-home-tools' folder: this file is in internal/shared/, two folders below it.
TOOLS_ROOT = Path(__file__).parent.parent.parent
SETTINGS_PATH = TOOLS_ROOT / "local-settings.json"


def read_settings() -> dict[str, Any] | None:
    """The settings, or None when the file is missing or isn't a JSON object."""
    try:
        data = json.loads(SETTINGS_PATH.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


@dataclass
class LocalSettings:
    """The settings setup asks for, with defaults for anything missing. is_new is True when
    there is no file yet, or an empty one. test_home_dir is only ever in a test sandbox's file,
    which the tests write; setup never adds it."""

    content_dir: str = ""
    auto_update: bool = False
    claude_config_dirs: list[str] = field(default_factory=list)
    test_home_dir: str = ""
    is_new: bool = True


def load_local_settings() -> LocalSettings | None:
    """The settings, or None when the file is there but can't be read as JSON."""
    settings = LocalSettings()
    if not SETTINGS_PATH.exists():
        return settings
    try:
        text = SETTINGS_PATH.read_text(encoding="utf-8-sig")
        # An empty file holds no answers yet, so it counts as no file.
        if not text.strip():
            return settings
        data = json.loads(text)
    except (OSError, ValueError):
        return None
    settings.is_new = False
    if not isinstance(data, dict):
        return settings
    if isinstance(data.get("contentDir"), str):
        settings.content_dir = data["contentDir"]
    settings.auto_update = data.get("autoUpdate") is True
    dirs = data.get("claudeConfigDirs")
    if isinstance(dirs, str):
        dirs = [dirs]
    if isinstance(dirs, list):
        settings.claude_config_dirs = [d for d in dirs if isinstance(d, str) and d]
    if isinstance(data.get("testHomeDir"), str):
        settings.test_home_dir = data["testHomeDir"]
    return settings


def save_local_settings(settings: LocalSettings) -> None:
    """Writes the settings back. testHomeDir is kept when the file has it, and never added."""
    data: dict[str, Any] = {
        "contentDir": settings.content_dir,
        "autoUpdate": settings.auto_update,
        "claudeConfigDirs": list(settings.claude_config_dirs),
    }
    if settings.test_home_dir:
        data["testHomeDir"] = settings.test_home_dir
    with SETTINGS_PATH.open("w", encoding="utf-8", newline="\n") as file:
        file.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
