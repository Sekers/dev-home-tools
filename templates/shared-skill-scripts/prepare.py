"""Prepares dev-home for a skill command: syncs it, then prints the facts asked for.

Called by: dev-home, handoff, knowledge

Every skill command that syncs dev-home starts with this script, so the agent gets what it needs
before its own work from one call. First it runs sync, which syncs dev-home with GitHub, checks
dev-home-tools for updates, and runs setup. --fetch always, auto, or when-due goes to the sync,
and says when it fetches dev-home (see sync.py); without it, the sync fetches every time. Then it
loads facts.py, the copy beside this one, which that setup run has just brought up to date, and
with it:

- checks the skill's stamp, given as --skill and --stamp as facts.py takes them. When the skill
  has changed since the agent loaded it, it prints a RELOAD line saying so, and no facts, because
  the agent's steps are out of date.
- prints the lines of the facts.py topics named after the options, if any.

The sync's lines come first, then the RELOAD line or the facts. It always exits 0. Everything it
has to say is in its lines: the sync's status lines, RELOAD, the facts, and a PROBLEM line when
the sync, facts.py, or this script stops. A failing exit code would make a tool report the whole
call as failed, and an agent could stop or retry instead of doing what the skill says about each
line.

The sync runs inside this process: it's the code of sync.py in dev-home-tools' root, which this
script loads from internal/shared/ there, as sync.py does, and the sync runs update's and
setup's code there too. facts.py runs inside this process as well. Everything this process
prints is written as UTF-8.

Committing is never done here: a skill commits through sync.py --message.

Examples, shortened: the skills give the full path of python.exe, which is
internal/.python/python.exe in dev-home-tools' folder, and of this script.

    python.exe -I prepare.py --skill handoff --stamp 3f9c2ab1d0e4 handoff environment newer-commits

Syncs dev-home, checks that the handoff skill hasn't changed, then prints where this project's
handoff is, the computer's name, and the project's commits since the handoff's last check.

    python.exe -I prepare.py --skill knowledge --stamp 3f9c2ab1d0e4 --fetch when-due

Syncs dev-home, fetching only when its check of GitHub is due, then checks that the knowledge
skill hasn't changed.
"""

import importlib
import importlib.util
import io
import sys
from pathlib import Path
from types import ModuleType

# dev-home-tools' folder, filled in by setup.
TOOLS_DIR = "{{TOOLS_DIR}}"


def write_status(state: str, message: str) -> None:
    """A status line in the same format as the sync's, which skills already handle."""
    print(f"{state:<9} {message}", flush=True)


def load_from_path(name: str, path: Path, folder: Path | None = None) -> ModuleType:
    """Loads a module, or with a folder a package, by its path: python -I leaves this script's
    folder off the import path."""
    locations = [str(folder)] if folder else None
    spec = importlib.util.spec_from_file_location(name, path, submodule_search_locations=locations)
    if spec is None or spec.loader is None:
        raise ImportError(f"{path} could not be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def without_fetch(argv: list[str]) -> tuple[list[str], list[str]]:
    """Splits --fetch and its value off the arguments: the sync takes them, and facts.py takes
    the rest."""
    rest = list(argv)
    if "--fetch" not in rest:
        return [], rest
    at = rest.index("--fetch")
    return rest[at : at + 2], rest[:at] + rest[at + 2 :]


def run_sync(sync_args: list[str]) -> None:
    """Runs the sync, which prints its own lines, PROBLEM lines included. It returns 1 when the
    user needs to act, and its lines already say why, so the number itself is ignored. When it
    can't be loaded, or stops, a PROBLEM line says so, and the facts still follow."""
    try:
        shared = Path(TOOLS_DIR) / "internal" / "shared"
        package = load_from_path("dev_home_tools_shared", shared / "__init__.py", shared)
        importlib.import_module(f"{package.__name__}.sync").main(sync_args)
    except Exception as error:
        write_status(
            "PROBLEM",
            f"The sync stopped, so dev-home may be behind: {type(error).__name__}: {error}. If an"
            f" update has a fix, the user installs it by hand: git -C {TOOLS_DIR} pull --ff-only,"
            f" then {'py' if sys.platform == 'win32' else 'python3'} {TOOLS_DIR}/setup.py",
        )


def main(argv: list[str]) -> int:
    """Syncs, then checks the skill's stamp and prints the facts. Always returns 0."""
    try:
        sync_args, facts_args = without_fetch(argv)
        run_sync(sync_args)
        facts = load_from_path("dev_home_facts", Path(__file__).with_name("facts.py"))
        try:
            request = facts.parse_request(facts_args)
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
