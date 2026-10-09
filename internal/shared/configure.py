"""setup.py --configure: changing a setting after the first run.

At a console, it shows a menu of every setting with its current value: a number changes one, a
goes through them all, and Enter finishes. Each entry asks the question the first run asks, from
setup's own steps, so a setting is asked about, checked, and written one way.

An agent can't answer at a console, so it gives one setting instead, as <name>=<value>, such as
autoUpdate=true, which its user approved in chat; nothing is asked. With neither a console nor a
setting, it shows the settings and how to change them.

This PC's settings go in local-settings.json, which setup saves with a dated backup. dev-home's
own setting, how many copies are in active use, goes in dev-home.json, which setup writes later in
its run, then commits and pushes, once dev-home's git config is in place.
"""

import copy
import json
import re
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING

from .output import CYAN, GREEN, color, status_line
from .paths import comparable, forward, is_inside, resolve_home, same_path, unsafe_reason
from .settings import (
    DEFAULT_HOURS,
    DEFAULT_SWITCHES,
    DEV_HOME_SETTINGS,
    SETTINGS_PATH,
    TOOLS_ROOT,
    LocalSettings,
    hours_setting,
    local_settings_text,
    switch_setting,
)

if TYPE_CHECKING:
    from .setup import Setup

NAMES = (
    "contentDir",
    "autoUpdate",
    "updateCheckHours",
    "contentCheckHours",
    "claudeConfigDirs",
    "offerSecurityBugs",
    "multiMachine",
)
ASSIGNMENT = re.compile(r"([A-Za-z]+)(\+=|-=|=)(.*)", re.DOTALL)
USAGE = """\
To change one setting, as an agent does, run setup.py --configure '<name>=<value>', in single
quotes, which every shell passes on as they are:

  contentDir=<folder>          Your dev-home folder: one that is already a dev-home.
  autoUpdate=true|false        Whether a sync installs dev-home-tools updates as soon as it
                               finds them.
  updateCheckHours=<hours>     How often a sync checks GitHub for dev-home-tools updates.
                               0 checks every time.
  contentCheckHours=<hours>    How often a sync checks GitHub for dev-home's changes, with one
                               active copy, and for a plain /knowledge. 0 checks every time.
  claudeConfigDirs+=<folder>   Set up another Claude Code folder, such as ~/.claude-second.
  claudeConfigDirs-=<folder>   Stop setting one up.
  offerSecurityBugs=true|false Whether the handoff skill offers a security bug as a GitHub
                               issue, with a warning. false never offers one.
  multiMachine=true|false      Whether dev-home is in active use anywhere besides this PC.
                               Every copy shares it, so setup commits and pushes the change.

Add --what-if to see the change without making it. In a terminal, --configure alone shows a menu
of every setting instead."""


class SettingError(Exception):
    """An assignment --configure can't make, and why."""


def change_settings(run: "Setup", settings: LocalSettings) -> bool:
    """Makes --configure's change to this PC's settings, or chooses dev-home.json's answer, which
    setup writes later in its run. Returns whether this PC's settings changed. With nobody to
    answer and no setting given, shows the settings and how to change them, and sets
    run.just_showing."""
    if run.assigned:
        return assign(run, settings, run.configure or "")
    if run.can_ask:
        return menu(run, settings)
    for line in overview(run, settings):
        run.line(line)
    run.line()
    run.line(USAGE)
    run.just_showing = True
    return False


# What the settings are now


def copies_answer(settings: LocalSettings) -> tuple[bool | None, bool]:
    """dev-home.json's answer to whether more than one copy is in active use, None for none
    yet, and whether the file could be read."""
    if not settings.content_dir:
        return None, True
    path = Path(comparable(settings.content_dir)) / DEV_HOME_SETTINGS
    if not path.exists():
        return None, True
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None, False
    if not isinstance(data, dict):
        return None, False
    answer = data.get("multiMachine")
    return (answer if isinstance(answer, bool) else None), True


def hours_value(settings: LocalSettings, key: str) -> str:
    hours, usable = hours_setting(settings.data, key)
    text = "every time" if hours == 0 else "every hour" if hours == 1 else f"every {hours} hours"
    if key not in settings.data:
        return text + " (the default)"
    if not usable:
        return f"{text} (the file says {json.dumps(settings.data[key])}, which isn't whole hours)"
    return text


def switch_value(settings: LocalSettings, key: str) -> str:
    yes, usable = switch_setting(settings.data, key)
    text = "yes" if yes else "no"
    if key not in settings.data:
        return text + " (the default)"
    if not usable:
        return f"{text} (the file says {json.dumps(settings.data[key])}, which isn't true or false)"
    return text


def folder_answers(run: "Setup", settings: LocalSettings) -> list[tuple[str, bool | None]]:
    """Each Claude folder setup knows of, as written in the settings, with its answer: each
    ~/.claude-* folder found, then any other folder listed."""
    answers: list[tuple[str, bool | None]] = []
    for folder in run.claude_folders():
        if run.listed(folder, settings.claude_config_dirs):
            answers.append(("~/" + folder.name, True))
        elif run.listed(folder, settings.declined_claude_config_dirs):
            answers.append(("~/" + folder.name, False))
        else:
            answers.append(("~/" + folder.name, None))
    for entry in settings.claude_config_dirs:
        full = resolve_home(entry, run.home)
        if not any(same_path(full, resolve_home(name, run.home)) for name, _ in answers):
            answers.append((entry, True))
    return answers


def overview(run: "Setup", settings: LocalSettings) -> list[str]:
    """Every setting and its value, numbered as the menu numbers them."""
    if settings.auto_update is None:
        auto_update = "not answered yet, so no"
    else:
        auto_update = "yes" if settings.auto_update else "no"
    answers = folder_answers(run, settings)
    words = {True: "yes", False: "no", None: "not asked yet"}
    folders = ", ".join(f"{name}: {words[answer]}" for name, answer in answers) or "none found"
    answer, readable = copies_answer(settings)
    if run.wanted_copies is not None:
        answer = run.wanted_copies
    if not readable:
        copies = f"{DEV_HOME_SETTINGS} can't be read"
    elif answer is None:
        copies = "not answered yet, so each sync checks GitHub"
    else:
        copies = "several" if answer else "one"
    this_pc = [
        ("dev-home folder", settings.content_dir or "not set yet"),
        ("Install dev-home-tools updates automatically", auto_update),
        ("Check GitHub for dev-home-tools updates", hours_value(settings, "updateCheckHours")),
        ("Check GitHub for dev-home's changes", hours_value(settings, "contentCheckHours")),
        ("Claude Code folders to set up", folders),
        ("Offer security bugs as GitHub issues", switch_value(settings, "offerSecurityBugs")),
    ]
    shared = [("Copies of dev-home in active use", copies)]
    width = max(len(label) for label, _ in this_pc + shared) + 2

    def row(number: int, label: str, value: str) -> str:
        return f"  {color(str(number), GREEN)}  {label:<{width}}{value}"

    lines = [color("dev-home-tools settings", CYAN), "", color("This PC", CYAN)]
    lines += [row(number, label, value) for number, (label, value) in enumerate(this_pc, 1)]
    lines += ["", color("Shared by every copy of dev-home", CYAN)]
    lines += [row(len(this_pc) + 1, label, value) for label, value in shared]
    return lines


# The menu


def menu(run: "Setup", settings: LocalSettings) -> bool:
    """Shows every setting, and changes the ones the person picks, until Enter."""
    steps: dict[str, Callable[[Setup, LocalSettings], bool]] = {
        "1": change_content_dir,
        "2": change_auto_update,
        "3": change_update_hours,
        "4": change_content_hours,
        "5": change_claude_folders,
        "6": change_security_bugs,
        "7": change_copies,
    }
    changed = False
    while True:
        run.line()
        for line in overview(run, settings):
            run.line(line)
        run.line()
        choice = run.ask("Number to change, a to go through them all, or Enter to finish")
        if not choice:
            return changed
        picked = list(steps) if choice.strip().lower() == "a" else [choice.strip()]
        if not all(number in steps for number in picked):
            run.line(f"Type a number from 1 to {len(steps)}, or a, or press Enter to finish.")
            continue
        for number in picked:
            changed = steps[number](run, settings) or changed


def change_content_dir(run: "Setup", settings: LocalSettings) -> bool:
    # Setup checks the folder next, as it does on a first run, and asks again if it isn't one.
    answer = run.ask("Your dev-home folder", settings.content_dir)
    if not answer or same_path(forward(answer), settings.content_dir or "."):
        return False
    settings.content_dir = forward(answer)
    return True


def change_auto_update(run: "Setup", settings: LocalSettings) -> bool:
    answer = run.ask_auto_update(settings.auto_update)
    if answer == settings.auto_update:
        return False
    settings.auto_update = answer
    return True


def change_hours(run: "Setup", settings: LocalSettings, key: str, question: str) -> bool:
    current = hours_setting(settings.data, key)[0]
    while True:
        answer = run.ask(question, str(current))
        if answer is None:
            return False
        if re.fullmatch(r"\d+", answer):
            break
        run.line("Type a whole number of hours: 0 or more.")
    hours = int(answer)
    # A default left unwritten moves with the default.
    if settings.data.get(key) == hours or (key not in settings.data and hours == current):
        return False
    settings.data[key] = hours
    return True


def change_update_hours(run: "Setup", settings: LocalSettings) -> bool:
    return change_hours(
        run,
        settings,
        "updateCheckHours",
        "Check GitHub for dev-home-tools updates every how many hours (0 for every sync)",
    )


def change_content_hours(run: "Setup", settings: LocalSettings) -> bool:
    run.line(
        "With one active copy, and for a plain /knowledge, a sync checks GitHub for dev-home's "
        "changes only this often."
    )
    return change_hours(
        run,
        settings,
        "contentCheckHours",
        "Check GitHub for dev-home's changes every how many hours (0 for every time)",
    )


def set_folder(settings: LocalSettings, run: "Setup", entry: str, yes: bool) -> None:
    """Puts a Claude folder in the list of folders to set up, or in the declined ones."""
    full = resolve_home(entry, run.home)
    for entries in (settings.claude_config_dirs, settings.declined_claude_config_dirs):
        entries[:] = [e for e in entries if not same_path(resolve_home(e, run.home), full)]
    (settings.claude_config_dirs if yes else settings.declined_claude_config_dirs).append(entry)


def change_claude_folders(run: "Setup", settings: LocalSettings) -> bool:
    answers = folder_answers(run, settings)
    if not answers:
        run.line("There are no ~/.claude-* folders to set up.")
        return False
    changed = False
    for entry, current in answers:
        answer = run.ask_claude_folder(Path(resolve_home(entry, run.home)), current)
        if answer != current:
            set_folder(settings, run, entry, answer)
            changed = True
    return changed


def change_security_bugs(run: "Setup", settings: LocalSettings) -> bool:
    key = "offerSecurityBugs"
    current = switch_setting(settings.data, key)[0]
    run.line(
        "After an update, the handoff skill can offer a bug as a GitHub issue. For a security "
        "bug, it warns"
    )
    run.line("that a public issue tells everyone about the hole before it's fixed.")
    answer = run.choose("Offer security bugs as GitHub issues, with that warning?", current)
    if answer is None:
        return False
    # A default left unwritten moves with the default.
    if settings.data.get(key) is answer or (key not in settings.data and answer == current):
        return False
    settings.data[key] = answer
    return True


def change_copies(run: "Setup", settings: LocalSettings) -> bool:
    """Chooses dev-home.json's answer, which setup writes, commits, and pushes later in its run.
    Changes nothing in this PC's settings."""
    answer, readable = copies_answer(settings)
    if not readable:
        run.line(f"{DEV_HOME_SETTINGS} in dev-home can't be read, so setup leaves it alone.")
        return False
    current = answer if run.wanted_copies is None else run.wanted_copies
    several = run.ask_copies(current)
    if several is None or several == current:
        return False
    if current is True and several is False:
        retired = run.choose(
            "Have all the other copies been retired, so this PC is the only one using dev-home?",
            False,
        )
        if not retired:
            run.line("dev-home stays set to several copies.")
            return False
    run.wanted_copies = None if several == answer else several
    return False


# One setting, from an agent


def assign(run: "Setup", settings: LocalSettings, text: str) -> bool:
    """Makes one assignment, and shows the change to this PC's settings, if any. Raises
    SettingError for one it can't make."""
    match = ASSIGNMENT.fullmatch(text.strip())
    if match is None:
        raise SettingError(f"--configure takes one setting as <name>=<value>, not {text}.")
    name, operator, value = match.group(1), match.group(2), match.group(3).strip()
    if name not in NAMES:
        raise SettingError(f"There is no setting named {name}.")
    if name == "claudeConfigDirs" and operator == "=":
        raise SettingError(
            "claudeConfigDirs changes one folder at a time: claudeConfigDirs+=<folder> sets one "
            "up, and claudeConfigDirs-=<folder> stops."
        )
    if name != "claudeConfigDirs" and operator != "=":
        raise SettingError(f"{name} is set with =, as in {name}=<value>.")
    before = copy.deepcopy(settings)
    if name in ("autoUpdate", "multiMachine", *DEFAULT_SWITCHES):
        if value.lower() not in ("true", "false"):
            raise SettingError(f"{name} is true or false, not {value}.")
        yes = value.lower() == "true"
        if name in DEFAULT_SWITCHES:
            settings.data[name] = yes
        elif name == "autoUpdate":
            settings.auto_update = yes
        else:
            answer, readable = copies_answer(settings)
            if not readable:
                raise SettingError(
                    f"{DEV_HOME_SETTINGS} in dev-home can't be read. The user fixes it by hand."
                )
            if answer == yes:
                status_line("OK", f"dev-home is already set to {'several' if yes else 'one'}.")
                return False
            run.wanted_copies = yes
            return False
    elif name in DEFAULT_HOURS:
        if not re.fullmatch(r"\d+", value):
            raise SettingError(f"{name} is a whole number of hours, 0 or more, not {value}.")
        settings.data[name] = int(value)
    elif name == "contentDir":
        settings.content_dir = checked_dev_home(value)
    else:
        if not value:
            raise SettingError("Name the Claude Code folder, such as ~/.claude-second.")
        full = Path(resolve_home(value, run.home))
        if operator == "+=" and not full.is_dir():
            raise SettingError(f"There is no Claude Code folder at {full}.")
        set_folder(settings, run, value, operator == "+=")
    old_text, new_text = local_settings_text(before), local_settings_text(settings)
    if old_text == new_text:
        status_line("OK", f"{name} is already set that way, so nothing changed.")
        return False
    run.status("CHANGE", f"This PC's settings: {SETTINGS_PATH}")
    run.print_diff(old_text, new_text)
    return True


def checked_dev_home(value: str) -> str:
    """A folder for contentDir, which must already be a dev-home: cloning or creating one takes
    a person's answers at a console."""
    # Loaded here, since setup loads this module.
    from .setup import is_in_use, missing_dev_home_files

    folder = forward(value)
    reason = unsafe_reason(folder)
    if reason:
        raise SettingError(f"The folder {folder} {reason}, so commands would need it quoted.")
    if is_inside(folder, TOOLS_ROOT):
        raise SettingError(f"The folder {folder} is dev-home-tools' own folder, or inside it.")
    full = Path(comparable(folder))
    if not is_in_use(full) or missing_dev_home_files(full):
        raise SettingError(
            f"{folder} isn't a dev-home: contentDir can only be a folder that already is one, "
            "with global-rules/global-rules.md and knowledge/README.md. To clone or create one, "
            "the user runs setup.py in a terminal."
        )
    return folder
