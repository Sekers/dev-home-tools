"""Prepares dev-home for a skill command: syncs it, then prints the facts asked for.

Called by: handoff, knowledge

Every skill command that syncs dev-home starts with this script, so the agent gets what it needs
before its own work from one call. First it runs sync.ps1, which syncs dev-home with GitHub,
checks dev-home-tools for updates, and runs setup. Then it loads facts.py, the copy beside this
one, which that setup run has just brought up to date, and with it:

- checks the skill's stamp, given as --skill and --stamp as facts.py takes them. When the skill
  has changed since the agent loaded it, it prints a RELOAD line saying so, and no facts, because
  the agent's steps are out of date.
- prints the lines of the facts.py topics named after the options, if any.

sync.ps1's lines come first, then the RELOAD line or the facts. It always exits 0. Everything it
has to say is in its lines: sync.ps1's status lines, RELOAD, the facts, and a PROBLEM line when
facts.py or this script stops. A failing exit code would make a tool report the whole call as
failed, and an agent could stop or retry instead of doing what the skill says about each line.

sync.ps1 runs in a PowerShell process of its own, and writes its lines straight to this
script's output. facts.py runs inside this process. This script's own lines, and the facts, are
written as UTF-8.

Committing is never done here: a skill commits through sync.ps1 -Message.

Examples, shortened: the skills give the full path of python.exe, which is .python/python.exe in
dev-home-tools' folder, and of this script.

    python.exe -I prepare.py --skill handoff --stamp 3f9c2ab1d0e4 handoff environment newer-commits

Syncs dev-home, checks that the handoff skill hasn't changed, then prints where this project's
handoff is, the computer's name, and the project's commits since the handoff's last check.

    python.exe -I prepare.py --skill knowledge --stamp 3f9c2ab1d0e4

Syncs dev-home, then checks that the knowledge skill hasn't changed.
"""

import importlib.util
import io
import os
import subprocess
import sys
from pathlib import Path
from types import ModuleType

# dev-home-tools' folder, filled in by setup.
TOOLS_DIR = "{{TOOLS_DIR}}"


def write_status(state: str, message: str) -> None:
    """A status line in the same format as sync.ps1's, which skills already handle."""
    print(f"{state:<9} {message}")


def find_pwsh() -> str | None:
    """PowerShell 7's full path, from the folders in PATH, never from the current folder, which
    here is a project's: a program of the same name there must never run."""
    name = "pwsh.exe" if sys.platform == "win32" else "pwsh"
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        if folder and Path(folder).is_absolute() and (Path(folder) / name).is_file():
            return str(Path(folder) / name)
    return None


def run_sync() -> None:
    """Runs sync.ps1, which prints its own lines, PROBLEM lines included. Its exit code is 1 when
    the user needs to act, and its lines already say why, so the code itself is ignored."""
    pwsh = find_pwsh()
    if pwsh is None:
        write_status(
            "PROBLEM",
            "PowerShell 7 (pwsh) was not found, so dev-home was not synced. "
            "Install it (see dev-home-tools' README), then try again.",
        )
        return
    sys.stdout.flush()
    subprocess.run(
        [pwsh, "-NoProfile", "-File", f"{TOOLS_DIR}/sync.ps1"],
        stdin=subprocess.DEVNULL,
        check=False,
    )


def load_facts() -> ModuleType:
    """Loads facts.py from beside this script, by its path: python -I leaves this script's
    folder off the import path."""
    path = Path(__file__).with_name("facts.py")
    spec = importlib.util.spec_from_file_location("dev_home_facts", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"{path} could not be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main(argv: list[str]) -> int:
    """Syncs, then checks the skill's stamp and prints the facts. Always returns 0."""
    try:
        run_sync()
        facts = load_facts()
        try:
            request = facts.parse_request(argv)
            changed = facts.skill_changed(request)
            if changed is not None:
                write_status("RELOAD", changed)
            elif request.topics:
                lines = facts.collect(request.topics)
                print("\n".join(lines))
        except facts.FactsError as error:
            write_status("PROBLEM", f"facts.py stopped, so there are no facts: {error}")
    except Exception as error:
        # Every failure becomes a line, so the agent always gets one to act on.
        write_status("PROBLEM", f"prepare.py stopped: {error}")
    return 0


if __name__ == "__main__":
    # Agents read UTF-8, but Python writes the console's code page when its output is redirected.
    for stream in (sys.stdout, sys.stderr):
        if isinstance(stream, io.TextIOWrapper):
            stream.reconfigure(encoding="utf-8")
    sys.exit(main(sys.argv[1:]))
