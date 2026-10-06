"""Claude Code's settings.json: which folders it lets Claude Code use, and planning the change that
adds dev-home and dev-home-tools to them."""

import json
from pathlib import Path
from typing import Any

from .settings_files import Plan, read_settings_file


def without_comments(text: str) -> str:
    """JSON text with // and /* */ comments taken out, outside strings."""
    out: list[str] = []
    index = 0
    in_string = False
    while index < len(text):
        char = text[index]
        if in_string:
            out.append(char)
            if char == "\\" and index + 1 < len(text):
                out.append(text[index + 1])
                index += 1
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
            out.append(char)
        elif text.startswith("//", index):
            while index < len(text) and text[index] != "\n":
                index += 1
            continue
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            index = len(text) if end < 0 else end + 2
            continue
        else:
            out.append(char)
        index += 1
    return "".join(out)


def folders_allowed(text: str) -> list[str] | None:
    """The folders in permissions.additionalDirectories, or None when the text isn't JSON even
    with comments taken out. Comments don't stop this check, though setup won't edit a file
    that has them. An empty file has none."""
    if not text.strip():
        return []
    try:
        data = json.loads(without_comments(text))
    except ValueError:
        return None
    if not isinstance(data, dict):
        return []
    permissions = data.get("permissions")
    folders = permissions.get("additionalDirectories") if isinstance(permissions, dict) else None
    if isinstance(folders, str):
        return [folders]
    if not isinstance(folders, list):
        return []
    return [folder for folder in folders if isinstance(folder, str)]


class RewrittenError(ValueError):
    """A number that writing the file back would change, such as 1e5, which would become
    100000.0."""


def no_repeats(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    keys = [key for key, _ in pairs]
    if len(set(keys)) != len(keys):
        raise ValueError("a key is there twice")
    return dict(pairs)


def exact_float(text: str) -> float:
    number = float(text)
    if json.dumps(number) != text:
        raise RewrittenError(text)
    return number


def exact_int(text: str) -> int:
    number = int(text)
    if str(number) != text:
        raise RewrittenError(text)
    return number


def not_a_number(text: str) -> float:
    """NaN and Infinity aren't JSON, though Python reads them."""
    raise ValueError(f"{text} is not JSON")


def read_json(text: str) -> Any:
    """Plain JSON only, read so that writing it back changes nothing but layout."""
    return json.loads(
        text,
        object_pairs_hook=no_repeats,
        parse_float=exact_float,
        parse_int=exact_int,
        parse_constant=not_a_number,
    )


def dump(data: object) -> str:
    """Two-space JSON, as Claude Code writes it."""
    return json.dumps(data, indent=2, ensure_ascii=False)


def plan(path: Path, entries: list[str]) -> Plan:
    """Plans adding folders to permissions.additionalDirectories. As a check, the new text is
    parsed again with the additions taken back out, and has to match the original exactly."""
    file = read_settings_file(path)
    result = Plan(file, reason=file.reason)
    if result.reason:
        return result
    try:
        data = read_json(file.text) if file.text.strip() else {}
    except RewrittenError as error:
        result.reason = f"rewriting it would change how its number {error} is written"
        return result
    except ValueError:
        result.reason = (
            "it is not plain JSON (it may have comments), and rewriting it would lose that"
        )
        return result
    if not isinstance(data, dict):
        result.reason = "its top level is not a JSON object"
        return result

    original = json.dumps(data)
    original_indented = dump(data)
    added = "entry"
    if "permissions" not in data:
        data["permissions"] = {}
        added = "permissions"
    permissions = data["permissions"]
    if permissions is None:
        result.reason = 'its "permissions" is null'
        return result
    if not isinstance(permissions, dict):
        result.reason = 'its "permissions" is not a JSON object'
        return result
    if "additionalDirectories" not in permissions:
        permissions["additionalDirectories"] = []
        if added == "entry":
            added = "list"
    folders = permissions["additionalDirectories"]
    if folders is None:
        result.reason = 'its "additionalDirectories" is null'
        return result
    if not isinstance(folders, list):
        result.reason = 'its "additionalDirectories" is not a list'
        return result
    folders.extend(entries)

    new_text = dump(data).replace("\n", file.newline)
    if file.final_newline:
        new_text += file.newline
    try:
        new_text.encode("utf-8")
    except UnicodeEncodeError:
        result.reason = (
            "it has a \\u escape for half a character (an unpaired surrogate), which can't be "
            "written back as UTF-8"
        )
        return result

    # Check: read the new text back, confirm the new entries, take the additions out again, and
    # compare what's left with the original.
    check = json.loads(new_text)
    check_list = check["permissions"]["additionalDirectories"]
    if check_list[len(check_list) - len(entries) :] != entries:
        result.reason = "a check of the planned change failed (a new entry did not read back)"
        return result
    if added == "permissions":
        del check["permissions"]
    elif added == "list":
        del check["permissions"]["additionalDirectories"]
    else:
        del check_list[len(check_list) - len(entries) :]
    if json.dumps(check) != original:
        result.reason = "a check of the planned change failed (the rest did not read back the same)"
        return result

    result.new_text = new_text
    if file.text.strip() and original_indented != file.text.replace("\r\n", "\n").rstrip("\n"):
        result.note = (
            "Some other lines change only in layout (spacing or escaping). "
            "The settings in them stay the same."
        )
    return result
