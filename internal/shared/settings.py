"""This PC's settings, from local-settings.json in dev-home-tools' folder. setup.ps1 writes it."""

import json
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
