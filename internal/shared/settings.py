"""This PC's settings, from local-settings.json in dev-home-tools' folder. setup.py writes it."""

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# dev-home-tools' folder: this file is in internal/shared/, two folders below it.
TOOLS_ROOT = Path(__file__).parent.parent.parent
SETTINGS_PATH = TOOLS_ROOT / "local-settings.json"
# dev-home's own settings, in its root, shared by every copy of it: for now, only multiMachine,
# whether more than one copy is in active use.
DEV_HOME_SETTINGS = "dev-home.json"

# How long, in whole hours, a sync goes without checking GitHub, when this PC's settings don't
# say: updateCheckHours for dev-home-tools' updates, and contentCheckHours for dev-home itself.
# 0 means every time.
DEFAULT_HOURS = {"updateCheckHours": 24, "contentCheckHours": 12}

# Yes-or-no settings, with what each is when this PC's settings don't say: offerSecurityBugs is
# whether the handoff skill offers a security bug as a GitHub issue candidate, with a warning.
# facts.py's settings topic reports it to the skill, with the same default (a test checks).
DEFAULT_SWITCHES = {"offerSecurityBugs": True}


def read_settings() -> dict[str, Any] | None:
    """The settings, or None when the file is missing or isn't a JSON object."""
    try:
        data = json.loads(SETTINGS_PATH.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def hours_setting(data: dict[str, Any], key: str) -> tuple[int, bool]:
    """A check interval from the settings, and whether the file's value could be used. A missing
    key, or a value that isn't a whole number of 0 or more, means the default."""
    default = DEFAULT_HOURS[key]
    if key not in data:
        return default, True
    value = data[key]
    # In Python, true and false are numbers too.
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value, True
    return default, False


def switch_setting(data: dict[str, Any], key: str) -> tuple[bool, bool]:
    """A yes-or-no setting, and whether the file's value could be used. A missing key, or a
    value that isn't true or false, means the default."""
    default = DEFAULT_SWITCHES[key]
    if key not in data:
        return default, True
    value = data[key]
    if isinstance(value, bool):
        return value, True
    return default, False


def folder_list(value: object) -> list[str]:
    """A list of folders from the settings: one folder on its own counts as a list of one."""
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        return []
    return [folder for folder in value if isinstance(folder, str) and folder]


@dataclass
class LocalSettings:
    """The settings setup asks for, with defaults for anything missing. auto_update is None until
    a person answers its question, and a sync treats that as off. A Claude folder goes in
    claude_config_dirs on a yes, and in declined_claude_config_dirs on a no, so setup asks about
    it only once. data holds everything the file had, so a save keeps the keys setup doesn't
    know. test_home_dir is only ever in a test sandbox's file, which the tests write; setup never
    adds it."""

    content_dir: str = ""
    auto_update: bool | None = None
    claude_config_dirs: list[str] = field(default_factory=list)
    declined_claude_config_dirs: list[str] = field(default_factory=list)
    test_home_dir: str = ""
    data: dict[str, Any] = field(default_factory=dict)


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
    if not isinstance(data, dict):
        return None
    settings.data = data
    if isinstance(data.get("contentDir"), str):
        settings.content_dir = data["contentDir"]
    if isinstance(data.get("autoUpdate"), bool):
        settings.auto_update = data["autoUpdate"]
    settings.claude_config_dirs = folder_list(data.get("claudeConfigDirs"))
    settings.declined_claude_config_dirs = folder_list(data.get("declinedClaudeConfigDirs"))
    if isinstance(data.get("testHomeDir"), str):
        settings.test_home_dir = data["testHomeDir"]
    return settings


def local_settings_text(settings: LocalSettings) -> str:
    """The file's text for the settings, keeping every other key the file had where it was.
    autoUpdate is written only once it's answered, and the declined Claude folders only once
    there are some. testHomeDir is kept when the file has it, and never added."""
    data = dict(settings.data)
    data["contentDir"] = settings.content_dir
    if settings.auto_update is not None:
        data["autoUpdate"] = settings.auto_update
    data["claudeConfigDirs"] = list(settings.claude_config_dirs)
    if settings.declined_claude_config_dirs or "declinedClaudeConfigDirs" in data:
        data["declinedClaudeConfigDirs"] = list(settings.declined_claude_config_dirs)
    if settings.test_home_dir:
        data["testHomeDir"] = settings.test_home_dir
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"
