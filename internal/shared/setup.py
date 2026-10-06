"""Sets up dev-home-tools on this PC: finds or creates your dev-home, fills in the skills and
operating rules with this PC's paths, links them into Claude Code and Codex, and checks the
settings they need.

Safe to run any number of times. It rewrites only its own generated files, creates missing links,
replaces links whose target is gone, removes links it made to skills that no longer exist, and
reports anything else without changing it.

On the first run it asks where your dev-home is (the private repo that holds your handoffs and
knowledge base), and saves the answer in local-settings.json in dev-home-tools' folder. If that
folder doesn't exist yet, it offers to clone your dev-home from GitHub, or to create a new
private one from the files in templates/dev-home-starter/.

The templates in this repo hold placeholders where paths go. Setup writes copies of the skills,
the scripts they share, and the operating rules, with this PC's paths filled in, to
internal/.generated/, at the same paths they have under templates/, and links the skills and
rules into the tools. Pre-approved commands must match the command text exactly, so the paths
can't be variables.

When a settings file is missing something, it shows the exact lines it would change and asks
first. On yes, it saves a dated backup of the file, then writes the change. It never edits a file
it can't fully parse (a settings.json with comments, for example), or a read-only one; it prints
what to add by hand instead.

Run it by hand once per PC. After that, each sync runs it with --quiet, so changes to the
skills, and skills added on another PC, reach this one.

Claude Code gets the links in ~/.claude, in each folder listed under claudeConfigDirs in
local-settings.json (one per extra Claude account; the first run offers each ~/.claude-* folder
it finds), and in the folder in CLAUDE_CONFIG_DIR when that's set. Codex gets them when it's
installed. Each link to a folder is a junction on Windows, which needs no Developer Mode, and a
symbolic link elsewhere.

The skills run their scripts with Python 3.12 or later, as internal/.python/python.exe in
dev-home-tools' folder: a junction setup makes to the folder of a Python it finds, so the
skills' commands name the same short path on every PC.

For testing, the tests in internal/development/tests/ run a throwaway copy of this repo whose
local-settings.json sets testHomeDir. Setup then uses that folder instead of your profile, and
says so on every run. It ignores a CLAUDE_CONFIG_DIR outside that folder. Setup never writes
testHomeDir itself.

Options:

    --quiet                 Print only changes and problems. Prints nothing when everything is
                            already in place. Never asks anything, because agents run setup
                            this way: anything that needs an answer is reported instead.
    --content-dir <folder>  Your dev-home folder. Saved in local-settings.json, so later runs
                            don't need it.
    --what-if               Shows what it would change, without changing anything.

It asks a question only when a person can see it and answer: never with --quiet, and only when
its input comes from a real console and its output goes to one. Input that ends without an
answer counts as no.

Examples, in dev-home-tools' folder, with Python 3.12 or later:

    py setup.py --what-if
    py setup.py

The sync runs main(["--quiet"]) inside its own process, so keep main's name and arguments.
"""

import contextlib
import os
import re
import stat
import subprocess
from collections.abc import Sequence
from pathlib import Path

from . import claude_settings, codex_config, console, generated, python_link
from .git import run_git
from .links import is_link, link_info, make_folder_link, remove_folder_link
from .output import GREEN, RED, YELLOW, color, describe, first_line, status_line
from .paths import comparable, forward, is_inside, resolve_home, same_path, unsafe_reason
from .programs import find_program
from .settings import (
    SETTINGS_PATH,
    TOOLS_ROOT,
    LocalSettings,
    load_local_settings,
    save_local_settings,
)
from .settings_files import (
    Plan,
    SettingsFile,
    line_diff,
    read_settings_file,
    to_lines,
    write_settings_file,
)

# Codex joins its global AGENTS.md with the project's AGENTS.md files and stops reading at
# project_doc_max_bytes, 32 KiB by default. The global file comes first, so the cut would fall on
# the project's own instructions, without a warning. Twice the default leaves room for long
# project files.
CODEX_DOC_BYTES = 65536
GENERATED_ROOT = TOOLS_ROOT / "internal" / ".generated"
PYTHON_LINK = TOOLS_ROOT / "internal" / ".python"
GENERATED_FOLDERS = ("skills", "shared-skill-scripts", "operating-rules")
FOLDER_NOTE = (
    "Setup writes everything in this folder from templates/skills/, "
    "templates/shared-skill-scripts/,\nand templates/operating-rules/, with this PC's paths "
    "filled in. Don't edit it: the next setup\nrun rewrites it. Python writes the __pycache__ "
    "folders when the scripts run, to start them\nfaster, and setup leaves those alone.\n"
)
QUIET_ADVICE = "Run setup.py without --quiet, and it offers to make the change."


class CannotGoOnError(Exception):
    """Ends the run early, after a problem that the rest of setup can't get past."""


class Setup:
    """One run of setup."""

    def __init__(self, *, quiet: bool, what_if: bool) -> None:
        self.quiet = quiet
        self.what_if = what_if
        self.can_ask = not quiet and console.is_console()
        self.problems: list[str] = []
        self.unknown_placeholders: list[str] = []
        self.unplaced_notes: list[str] = []
        self.generated_changes = 0
        # The profile folder to set up: yours, unless local-settings.json sets testHomeDir.
        self.home = Path.home()

    # Talking to the person

    def line(self, text: str = "", code: str = "") -> None:
        print(color(text, code) if code else text, flush=True)

    def status(self, state: str, message: str) -> None:
        """A status line, counted: problems set the exit code. With --quiet, OK lines are left
        out."""
        if state == "PROBLEM":
            self.problems.append(message)
        if self.quiet and state == "OK":
            return
        status_line(state, message)

    def should(self, target: object, action: str) -> bool:
        """Whether to make a change. With --what-if, says what it would do instead."""
        if self.what_if:
            self.line(f"What if: {action}: {target}")
            return False
        return True

    def ask(self, question: str, default: str = "") -> str | None:
        return console.ask(question, default) if self.can_ask else None

    def confirm(self, question: str) -> bool:
        return console.confirm(question) if self.can_ask else False

    def finish(self) -> int:
        """Prints the summary, and returns 0 when there were no problems, 1 otherwise."""
        if self.what_if and not self.quiet:
            self.line()
            self.line("This was a preview (--what-if). Nothing was changed.", YELLOW)
        if not self.problems:
            if not (self.quiet or self.what_if):
                self.line()
                self.line("All checks passed.", GREEN)
            return 0
        if not self.quiet:
            self.line()
            self.line(f"{len(self.problems)} problem(s) to fix. Run setup.py again afterward.", RED)
        return 1

    # Generated files

    def sync_generated_folder(
        self,
        destination: Path,
        values: dict[str, str],
        source: Path | None = None,
        note_file: str = "",
        note_text: str = "",
    ) -> None:
        """Makes destination hold exactly the files in source, with the placeholders filled in,
        and note_text added to note_file (a path relative to source). With no source, empties
        destination and removes it."""
        # Something else made a link here, or in a folder above here, and it may point anywhere,
        # so setup neither writes through it nor empties it.
        linked = linked_folder(destination)
        if linked is not None:
            self.status(
                "PROBLEM",
                f"{linked} is a link, so setup left it alone. Setup writes that folder "
                "itself: remove the link with cmd /c rmdir, then run setup.py again.",
            )
            return

        source_files = list(generated.generated_items(source)) if source else []
        wanted = {os.path.normcase(os.path.relpath(f, source)) for f in source_files if source}

        # Old files and empty folders go first, so that a path that was a folder can become a
        # file, and the other way around. Python's bytecode cache stays while the folder has
        # templates.
        if destination.exists():
            for file in list(generated.generated_items(destination, with_cache=source is None)):
                if os.path.normcase(os.path.relpath(file, destination)) in wanted:
                    continue
                if not self.should(file, "Remove a generated file whose template is gone"):
                    continue
                try:
                    remove_generated_file(file)
                except OSError as error:
                    self.status("PROBLEM", f"Could not remove the generated file {file}. {error}")
                    continue
                self.generated_changes += 1
            # Empty folders, deepest first.
            folders = sorted(
                generated.generated_items(destination, directories=True, with_cache=source is None),
                key=lambda folder: len(str(folder)),
                reverse=True,
            )
            if source is None:
                folders.append(destination)
            for folder in folders:
                if any(folder.iterdir()):
                    continue
                if self.should(folder, "Remove an empty generated folder"):
                    try:
                        folder.rmdir()
                    except OSError as error:
                        self.status(
                            "PROBLEM",
                            f"Could not remove the empty generated folder {folder}. {error}",
                        )

        for file in source_files:
            assert source is not None
            relative = os.path.relpath(file, source)
            target = destination / relative
            same_note_file = os.path.normcase(relative) == os.path.normcase(note_file)
            rendered = generated.render(
                file, values, note_text if note_file and same_note_file else ""
            )
            self.unknown_placeholders.extend(rendered.unknown)
            if rendered.unplaced:
                self.unplaced_notes.append(str(file))
            # A link to a file may point anywhere, so setup doesn't write through it.
            if is_link(target):
                self.status(
                    "PROBLEM",
                    f"{target} is a link, so setup left it alone. Setup writes that file itself: "
                    "remove the link, then run setup.py again.",
                )
                continue
            if target.is_file() and target.read_bytes() == rendered.data:
                continue
            if not self.should(target, "Write a generated file"):
                continue
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.is_file():
                    make_writable(target)
                target.write_bytes(rendered.data)
            except OSError as error:
                self.status("PROBLEM", f"Could not write the generated file {target}. {error}")
                continue
            self.generated_changes += 1

    # dev-home itself

    def initialize_content_repo(self, path: Path, values: dict[str, str]) -> None:
        """Offers to clone the person's dev-home from GitHub, or to create a new private one
        from templates/dev-home-starter/. The caller checks the folder afterward."""
        if not self.can_ask:
            self.status(
                "PROBLEM",
                f"There is no dev-home at {path}. Run setup.py in a terminal without --quiet, and "
                "it offers to clone yours from GitHub or create a new one.",
            )
            return
        gh = find_program("gh")
        if gh is None:
            self.status(
                "PROBLEM",
                f"There is no dev-home at {path}, and cloning or creating one needs the GitHub "
                "CLI (gh). Install it, sign in with gh auth login, then run setup.py again.",
            )
            return
        if run_tool(gh, "auth", "status")[0] != 0:
            self.status(
                "PROBLEM",
                f"There is no dev-home at {path}, and the GitHub CLI is not signed in. Run gh "
                "auth login, then run setup.py again.",
            )
            return

        self.line(f"There is no dev-home at {path} yet.")
        choice = self.ask(
            "Clone your existing dev-home from GitHub (c), create a new private one (n), or stop "
            "here (s)?",
            "s",
        )
        stopped = f"Stopped: there is no dev-home at {path} yet."
        if choice is not None and re.fullmatch(r"\s*(c|clone)\s*", choice, re.IGNORECASE):
            name = self.ask(
                "Your dev-home repo on GitHub: owner/name, or just the name if it is under your "
                "account",
                "dev-home",
            )
            # Input that ends without an answer counts as no, here as anywhere.
            if name is None:
                self.status("PROBLEM", stopped)
                return
            if not self.should(path, f"Clone {name} from GitHub"):
                return
            code, lines = run_tool(gh, "repo", "clone", name, str(path))
            if code != 0:
                self.status("PROBLEM", f"Could not clone {name}. gh: {first_line(lines)}")
                return
            self.status("CREATED", f"Cloned {name} into {path}")
            return
        if choice is None or not re.fullmatch(r"\s*(n|new)\s*", choice, re.IGNORECASE):
            self.status("PROBLEM", stopped)
            return

        name = self.ask("Name for the new private repo on GitHub", "dev-home")
        if name is None:
            self.status("PROBLEM", stopped)
            return
        action = f"Create a private repo named {name} on GitHub, from templates/dev-home-starter/"
        if not self.should(path, action):
            return
        path.mkdir(parents=True, exist_ok=True)
        starter = TOOLS_ROOT / "templates" / "dev-home-starter"
        files: list[str] = []
        for file in sorted(f for f in starter.rglob("*") if f.is_file()):
            relative = file.relative_to(starter)
            target = path / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            rendered = generated.render(file, values)
            self.unknown_placeholders.extend(rendered.unknown)
            target.write_bytes(rendered.data)
            files.append(relative.as_posix())
        steps = [
            ["init", "--quiet", "-b", "main"],
            ["config", "--local", "commit.gpgsign", "false"],
            ["config", "--local", "pull.rebase", "false"],
            ["add", "--", *files],
            ["commit", "--quiet", "-m", "starter: new dev-home"],
        ]
        for step in steps:
            done = run_git(path, *step)
            if done.code != 0:
                self.status(
                    "PROBLEM",
                    f"Could not set up the repo in {path}: git {step[0]} failed. "
                    f"git: {first_line(done.err + done.out)}",
                )
                return
        code, lines = run_tool(
            gh,
            "repo",
            "create",
            name,
            "--private",
            "--source",
            str(path),
            "--remote",
            "origin",
            "--push",
        )
        if code != 0:
            self.status(
                "PROBLEM",
                f"Created dev-home in {path}, but not on GitHub. gh: {first_line(lines)}. Once "
                f"that is fixed, run: gh repo create {name} --private --source {path} --remote "
                "origin --push",
            )
            return
        self.status("CREATED", f"New private repo {name} on GitHub, with this PC's copy in {path}")

    # Links

    def sync_link(self, link: Path, target: Path, label: str) -> None:
        existing = link_info(link)
        wanted = comparable(target)

        # A link whose target is gone has nothing to lose, such as one left from an older layout.
        if (
            existing is not None
            and existing.is_link
            and existing.target is not None
            and not same_path(existing.target, wanted)
            and not Path(existing.target).exists()
        ):
            if not self.should(link, f"Replace a link to {existing.target}, which is gone"):
                return
            try:
                remove_folder_link(link)
                existing = None
            except OSError as error:
                self.status("PROBLEM", f"{label}: could not remove the broken link {link}. {error}")
                return

        if existing is None:
            if not self.should(link, f"Create a link to {target}"):
                return
            try:
                kind = make_folder_link(link, target)
                self.status("LINKED", f"{label} ({kind}): {link}")
            except OSError as error:
                self.status("PROBLEM", f"{label}: could not create {link}. {error}")
            return
        if not existing.is_link:
            self.status(
                "PROBLEM",
                f"{label}: {link} already exists and is not a link. Move anything you need from "
                "it into dev-home, delete it, then run setup.py again.",
            )
            return
        if existing.target is not None and same_path(existing.target, wanted):
            self.status("OK", label)
            return
        self.status(
            "PROBLEM",
            f"{label}: {link} links to {existing.target}, not to {target}. Left alone. If you no "
            "longer need it, remove it with cmd /c rmdir, then run setup.py again.",
        )

    def sync_codex_rules(
        self, operating_template: Path, global_path: Path, values: dict[str, str], note_text: str
    ) -> None:
        """Codex reads a single always-on file, so setup writes the operating rules and the
        person's global rules into it, joined, under one note naming both. The operating rules
        come from their template rather than Claude Code's generated copy, which has a note of
        its own. It replaces only a file it wrote, or a link whose target is gone."""
        path = self.home / ".codex" / "AGENTS.md"
        label = "Codex always-on rules"
        parts = [
            note_text,
            generated.render(operating_template, values).data.decode("utf-8").rstrip("\n"),
        ]
        if global_path.is_file():
            parts.append(generated.read_text(global_path).rstrip("\n"))
        text = "\n\n".join(parts) + "\n"

        existing = link_info(path)
        if existing is not None:
            if existing.is_link:
                if existing.target is not None and Path(existing.target).exists():
                    self.status(
                        "PROBLEM",
                        f"{label}: {path} links to {existing.target}. Left alone. Move anything "
                        f"you want to keep into {global_path}, delete the link, then run setup.py "
                        "again.",
                    )
                    return
                if not self.should(path, "Replace this link with the joined rules file"):
                    return
                path.unlink()
            else:
                current = path.read_bytes().decode("utf-8-sig", errors="replace")
                if not current.startswith(generated.MARKER):
                    self.status(
                        "PROBLEM",
                        f"{label}: {path} already exists, and setup did not write it. Move "
                        f"anything you want to keep into {global_path}, delete the file, then run "
                        "setup.py again.",
                    )
                    return
                if current == text:
                    self.status("OK", label)
                    return
        if not self.should(path, "Write the operating and global rules, joined"):
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="") as file:
            file.write(text)
        self.status("WROTE", f"{label}: {path}")

    # Python, for the skills' scripts

    def sync_python_link(self, local_app_data: Path, *, skip_registry: bool) -> None:
        """Makes internal/.python a junction to the folder of a Python 3.12 or later, so the
        skills' commands name the same short path on every PC, with no spaces to quote. Each
        run only checks that the link's python.exe is there, which starts no process. It looks
        for a Python, which does, only to make the link, or to re-point it once that python.exe
        is gone."""
        label = "Python for the skills"
        existing = link_info(PYTHON_LINK)
        if existing is not None and not existing.is_link:
            self.status(
                "PROBLEM",
                f"{label}: {PYTHON_LINK} already exists and is not a link. Setup makes a junction "
                "there to a Python install. Move it aside, then run setup.py again.",
            )
            return
        if existing is not None and (PYTHON_LINK / "python.exe").is_file():
            self.status("OK", f"{label}: {existing.target}")
            return
        folder = next(
            (
                candidate
                for candidate in python_link.candidates(local_app_data, skip_registry=skip_registry)
                if python_link.is_new_enough(candidate)
            ),
            None,
        )
        if folder is None:
            self.status(
                "PROBLEM",
                f"{label}: no Python 3.12 or later was found, and the skills run their scripts "
                "with it. Install it with the Python install manager (see the README's "
                "Requirements), then run setup.py again.",
            )
            return
        if not self.should(PYTHON_LINK, f"Link to the Python in {folder}"):
            return
        try:
            if existing is not None:
                remove_folder_link(PYTHON_LINK)
            kind = make_folder_link(PYTHON_LINK, folder)
            self.status("LINKED", f"{label} ({kind}): {PYTHON_LINK} -> {folder}")
        except OSError as error:
            self.status("PROBLEM", f"{label}: could not link {PYTHON_LINK} to {folder}. {error}")

    # Settings changes. Each change is planned in full first, checked by reading the new text
    # back, shown as a line diff, and written only after a yes, with a backup.

    def repair_setting(
        self,
        subject: str,
        path: Path,
        need: str,
        plan: Plan,
        how_to: str,
        snippet: str,
        quiet_advice: str = QUIET_ADVICE,
    ) -> None:
        """Offers a planned settings change: shows the changed lines, asks, then writes the file
        with a backup. When the change can't be made safely, the answer is no, or setup runs
        with --quiet, it reports a problem and leaves the file alone. With --quiet, the problem
        ends with quiet_advice."""
        problem = f"{subject}: {path} needs {need}."
        if plan.reason:
            self.status("PROBLEM", problem)
            if not self.quiet:
                self.line(f"          Setup won't change this file itself: {plan.reason}.")
                self.line("          " + how_to)
                self.line(snippet, YELLOW)
            return
        if self.quiet:
            self.status("PROBLEM", f"{problem} {quiet_advice}")
            return

        self.status("CHANGE", problem)
        self.line(
            "          Setup can make this change, and keeps a backup of the file first. Lines "
            "marked + are added, - removed:"
        )
        if plan.note:
            self.line("          " + plan.note)
        diff = line_diff(to_lines(plan.file.text), to_lines(plan.new_text or ""))
        limit = 40
        for diff_line in diff[:limit]:
            code = (
                GREEN if diff_line.startswith("+ ") else RED if diff_line.startswith("- ") else ""
            )
            self.line("            " + diff_line, code)
        if len(diff) > limit:
            self.line(f"            ...and {len(diff) - limit} more lines.")

        if not self.should(path, "Change the lines shown, after asking, and keep a backup"):
            return
        if not self.confirm("          Make this change?"):
            self.status(
                "PROBLEM",
                f"{subject}: left unchanged. Make the change shown above by hand, or run setup.py "
                "again and answer y.",
            )
            return
        try:
            now = read_settings_file(path)
            if now.reason or now.text != plan.file.text:
                raise OSError(
                    "The file changed while setup was waiting for an answer, so it was left "
                    "alone. Run setup.py again."
                )
            backup = write_settings_file(path, plan.new_text or "", bom=plan.file.bom)
            saved = f" Backup of the old file: {backup}" if backup else " (new file)"
            self.status("SET", f"{subject}: changed {path}.{saved}")
        except (OSError, ValueError) as error:
            self.status("PROBLEM", f"{subject}: could not write {path}. {error}")

    # The run, in order

    def run(self, content_dir_option: str) -> None:
        # 1. Where things are
        tools_problem = unsafe_reason(comparable(TOOLS_ROOT))
        if tools_problem:
            self.status(
                "PROBLEM",
                f"dev-home-tools is at {comparable(TOOLS_ROOT)}, which {tools_problem}. Setup "
                "writes this path into commands as it is, so move the folder, then run setup.py "
                "again.",
            )
            raise CannotGoOnError
        loaded = load_local_settings()
        if loaded is None:
            self.status(
                "PROBLEM",
                f"{SETTINGS_PATH} could not be read as JSON. Fix it, or delete it and answer the "
                "questions again, then run setup.py again.",
            )
            raise CannotGoOnError
        settings: LocalSettings = loaded
        if settings.test_home_dir:
            self.home = Path(comparable(settings.test_home_dir))
            if not self.home.is_dir():
                self.status(
                    "PROBLEM",
                    f"local-settings.json sets testHomeDir to {self.home}, which does not exist.",
                )
                raise CannotGoOnError
            self.status(
                "TEST",
                f"Using the test profile {self.home} instead of {Path.home()}, because "
                "local-settings.json sets testHomeDir.",
            )
        save = False
        if content_dir_option:
            wanted = forward(content_dir_option)
            if settings.content_dir != wanted:
                settings.content_dir = wanted
                save = True
        elif not settings.content_dir:
            default = forward(TOOLS_ROOT.parent / "dev-home")
            if self.can_ask:
                self.line(
                    "dev-home is your private repo for handoffs and a knowledge base. Setup needs "
                    "its folder on this PC:"
                )
                self.line(
                    "where it is now, or where it should go. Press Enter to accept the suggestion "
                    "in brackets."
                )
            answer = self.ask("Your dev-home folder", default)
            if answer is None:
                self.status(
                    "PROBLEM",
                    "This PC has no dev-home folder set. Run setup.py once in a terminal without "
                    "--quiet, and it asks for one.",
                )
                raise CannotGoOnError
            settings.content_dir = forward(answer)
            save = True

        # Checked as setup will use it, so a hand-edited C:/dev-home/.. counts as the drive root
        # it leads to.
        content_problem = unsafe_reason(forward(settings.content_dir))
        if content_problem:
            self.status(
                "PROBLEM",
                f"The dev-home folder {settings.content_dir} {content_problem}. Setup writes this "
                "path into commands as it is. Choose another folder with --content-dir.",
            )
            raise CannotGoOnError
        if is_inside(settings.content_dir, TOOLS_ROOT):
            self.status(
                "PROBLEM",
                f"The dev-home folder {settings.content_dir} is dev-home-tools' own folder, or "
                "inside it. Choose your dev-home's folder with --content-dir.",
            )
            raise CannotGoOnError

        if settings.is_new and self.can_ask:
            self.line(
                "sync.py can pull dev-home-tools updates on every sync, or only tell you when "
                "there are some,"
            )
            self.line("so you can look at them first and pull them with update.py.")
            settings.auto_update = self.confirm("Pull updates automatically?")
            # Another Claude account run with CLAUDE_CONFIG_DIR has its own folder, usually
            # ~/.claude-<name>.
            for folder in sorted(self.home.iterdir()):
                is_claude = folder.is_dir() and folder.name.lower().startswith(".claude-")
                if is_claude and self.confirm(f"Also set up {folder}, for another Claude account?"):
                    settings.claude_config_dirs.append("~/" + folder.name)
            save = True

        if save and self.should(SETTINGS_PATH, "Save this PC's settings"):
            save_local_settings(settings)
            self.status("SET", f"This PC's settings: {SETTINGS_PATH}")

        content_root = Path(comparable(settings.content_dir))
        values = {
            "TOOLS_DIR": forward(TOOLS_ROOT),
            "CONTENT_DIR": forward(content_root),
            "SHARED_SKILL_SCRIPTS_DIR": forward(GENERATED_ROOT / "shared-skill-scripts"),
            "PYTHON": forward(PYTHON_LINK / "python.exe"),
        }
        # The operating rules template and the person's global rules, each named once: setup
        # reads them from here, and the notes in generated files point to them.
        operating_template = TOOLS_ROOT / "templates" / "operating-rules" / "operating-rules.md"
        global_rules_file = content_root / "global-rules" / "global-rules.md"

        # 2. dev-home itself: clone or create it when it's missing, then set its repo-local git
        # config.
        missing = not content_root.is_dir() or not any(content_root.iterdir())
        if missing:
            self.initialize_content_repo(content_root, values)
            if not (content_root / ".git").exists():
                if self.what_if:
                    self.line(
                        "What if: the rest of setup works with dev-home, so it can't be previewed "
                        "until dev-home exists."
                    )
                raise CannotGoOnError
        if not (content_root / ".git").exists():
            self.status(
                "PROBLEM",
                f"{content_root} is not a git repo. Point setup at your dev-home with "
                "--content-dir, or move that folder aside so setup can clone or create one there.",
            )
            raise CannotGoOnError
        # A repo with no commits is most likely a new dev-home that setup couldn't finish, for
        # example because git doesn't know the person's name and email yet. Starting over is the
        # simple fix. Only exit code 1 means no commits: anything else is git failing to read
        # the repo, which says nothing about what's in it.
        head = run_git(content_root, "rev-parse", "--verify", "--quiet", "HEAD")
        if head.code == 1:
            self.status(
                "PROBLEM",
                f"{content_root} is a git repo with no commits, probably from a setup run that "
                "stopped partway. If it holds nothing you need, delete the folder, fix what "
                "stopped setup, then run setup.py again to clone or create dev-home there.",
            )
            raise CannotGoOnError
        if head.code != 0:
            self.status(
                "PROBLEM",
                f"git could not read {content_root}, so setup stopped. "
                f"git: {first_line(head.err + head.out)}",
            )
            raise CannotGoOnError

        # No signing prompts for agent commits, and pulls that merge rather than rebase, as
        # sync.py does, because a rebase refuses to run while any file is uncommitted.
        for key, value in (("commit.gpgsign", "false"), ("pull.rebase", "false")):
            current = run_git(content_root, "config", "--local", "--get", key)
            if first_line(current.out) == value:
                self.status("OK", f"dev-home git config {key} = {value}")
            elif self.should(f"git config --local {key} in {content_root}", f"Set to {value}"):
                if run_git(content_root, "config", "--local", key, value).code == 0:
                    self.status("SET", f"dev-home git config {key} = {value}")
                else:
                    self.status("PROBLEM", f"Could not set git config {key} in {content_root}.")

        # 3. Python, for the skills' scripts. A test profile has its own AppData folder.
        if settings.test_home_dir:
            local_app_data = self.home / "AppData" / "Local"
        else:
            local_app_data = Path(
                os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local"
            )
        self.sync_python_link(local_app_data, skip_registry=bool(settings.test_home_dir))

        # 4. Generated files: the skills, the scripts they share, and the operating rules, with
        # this PC's paths filled in, at the same paths they have under templates/. The file each
        # tool loads, a skill's SKILL.md or the operating rules, gets a note naming its
        # template, because an agent in another project only ever sees this copy, and an edit
        # here is lost at the next setup run. No other file gets one: the handoff template, for
        # one, is copied into every new handoff.
        skill_sources = sorted(
            folder
            for folder in (TOOLS_ROOT / "templates" / "skills").iterdir()
            if folder.is_dir() and (folder / "SKILL.md").is_file()
        )
        generated_skills = GENERATED_ROOT / "skills"
        for skill in skill_sources:
            destination = generated_skills / skill.name
            skill_values = dict(values)
            skill_values["SKILL_DIR"] = forward(destination)
            skill_values["SKILL_STAMP"] = generated.skill_stamp(skill / "SKILL.md", skill_values)
            skill_note = generated.note(
                f"{forward(skill)}/",
                "Changing the skill there changes dev-home-tools itself; skills of your own go "
                f"in {values['CONTENT_DIR']}/skills/.",
            )
            self.sync_generated_folder(destination, skill_values, skill, "SKILL.md", skill_note)
        skill_names = {os.path.normcase(skill.name) for skill in skill_sources}
        if generated_skills.exists():
            for folder in sorted(generated_skills.iterdir()):
                stale = os.path.normcase(folder.name) not in skill_names
                if folder.is_dir() and not is_link(folder) and stale:
                    self.sync_generated_folder(folder, values)
        rules_note = generated.note(
            forward(operating_template),
            f"Put rules of your own in {forward(global_rules_file)}; changing the template "
            "changes dev-home-tools itself.",
        )
        self.sync_generated_folder(
            GENERATED_ROOT / "operating-rules",
            values,
            operating_template.parent,
            operating_template.name,
            rules_note,
        )
        # The scripts the skills share. The skills run them from here, at the path
        # SHARED_SKILL_SCRIPTS_DIR gives.
        self.sync_generated_folder(
            GENERATED_ROOT / "shared-skill-scripts",
            values,
            TOOLS_ROOT / "templates" / "shared-skill-scripts",
        )
        # A folder here with no templates, such as one left from an older layout, is removed.
        # A link here isn't setup's, so it stays.
        if GENERATED_ROOT.exists():
            for folder in sorted(GENERATED_ROOT.iterdir()):
                stale = folder.name.lower() not in GENERATED_FOLDERS
                if folder.is_dir() and not is_link(folder) and stale:
                    self.sync_generated_folder(folder, values)
        note_path = GENERATED_ROOT / "README.txt"
        note_differs = not note_path.exists() or note_path.read_bytes() != FOLDER_NOTE.encode(
            "utf-8"
        )
        if (
            note_differs
            and GENERATED_ROOT.exists()
            and linked_folder(GENERATED_ROOT) is None
            and self.should(note_path, "Write a note about this folder")
        ):
            with note_path.open("w", encoding="utf-8", newline="") as file:
                file.write(FOLDER_NOTE)

        for unknown in dict.fromkeys(self.unknown_placeholders):
            self.status("PROBLEM", f"A placeholder setup does not know, left as it is: {unknown}")
        for unplaced in dict.fromkeys(self.unplaced_notes):
            self.status(
                "PROBLEM",
                f"{unplaced} starts with frontmatter that has no closing --- line, so its "
                "generated copy has no note saying not to edit it. Close the frontmatter with a "
                "line of three dashes.",
            )
        label = "Skills, their shared scripts, and operating rules with this PC's paths"
        if self.generated_changes > 0:
            self.status(
                "WROTE", f"{label}: {self.generated_changes} file(s) changed in {GENERATED_ROOT}"
            )
        else:
            self.status("OK", label)

        # 5. Skills, linked into each tool's personal skills folder: the dev-home-tools skills,
        # then the personal skills in dev-home.
        codex_installed = (self.home / ".codex").exists()
        using_real_home = same_path(self.home, Path.home())
        default_claude_dir = comparable(self.home / ".claude")
        candidates = [default_claude_dir, *settings.claude_config_dirs]
        # The Claude folder of the session running setup, which may be in no list. A test
        # profile takes it only from inside itself, so the real one is never touched.
        session_claude_dir = None
        if os.environ.get("CLAUDE_CONFIG_DIR"):
            session_claude_dir = comparable(
                resolve_home(os.environ["CLAUDE_CONFIG_DIR"], self.home)
            )
            inside_home = os.path.normcase(session_claude_dir).startswith(
                os.path.normcase(comparable(self.home)) + os.sep
            )
            if not (using_real_home or inside_home):
                session_claude_dir = None
        if session_claude_dir:
            candidates.append(session_claude_dir)
        # A run without --quiet usually has no CLAUDE_CONFIG_DIR, so it sees that folder only
        # once it's listed.
        listed = [
            comparable(resolve_home(d, self.home)) for d in settings.claude_config_dirs if d.strip()
        ]
        unlisted_claude_dir = None
        if (
            session_claude_dir
            and not same_path(session_claude_dir, default_claude_dir)
            and not any(same_path(session_claude_dir, d) for d in listed)
        ):
            unlisted_claude_dir = session_claude_dir
        claude_dirs: list[str] = []
        for candidate in candidates:
            if not candidate.strip():
                continue
            full = comparable(resolve_home(candidate, self.home))
            if not same_path(full, default_claude_dir) and not Path(full).exists():
                self.status(
                    "PROBLEM",
                    f"The Claude folder {full}, listed in {SETTINGS_PATH}, does not exist.",
                )
                continue
            if not any(same_path(full, d) for d in claude_dirs):
                claude_dirs.append(full)

        tool_skill_folders = [Path(d) / "skills" for d in claude_dirs]
        if codex_installed:
            tool_skill_folders.append(self.home / ".agents" / "skills")

        links: list[tuple[str, Path]] = [
            (skill.name, generated_skills / skill.name) for skill in skill_sources
        ]
        personal_skills = content_root / "skills"
        if personal_skills.exists():
            for skill_folder in sorted(personal_skills.iterdir()):
                if not (skill_folder.is_dir() and (skill_folder / "SKILL.md").is_file()):
                    continue
                if any(
                    os.path.normcase(name) == os.path.normcase(skill_folder.name)
                    for name, _ in links
                ):
                    self.status(
                        "PROBLEM",
                        f"Your personal skill '{skill_folder.name}' has the same name as a "
                        "dev-home-tools skill, so it isn't linked. Rename its folder and its name "
                        "field.",
                    )
                    continue
                links.append((skill_folder.name, skill_folder))

        # Links into these folders are setup's own, so one whose skill is gone can be removed.
        # A link for a skill that's still here stays, even when its generated folder is missing.
        owned = [
            os.path.normcase(comparable(f)) + os.sep for f in (generated_skills, personal_skills)
        ]
        current_skills = {os.path.normcase(name) for name, _ in links}
        for folder in tool_skill_folders:
            for name, target in links:
                self.sync_link(folder / name, target, f"Skill '{name}' in {folder}")
            if not folder.exists():
                continue
            for entry in sorted(folder.iterdir()):
                if os.path.normcase(entry.name) in current_skills:
                    continue
                found = link_info(entry)
                if found is None or not found.is_link or found.target is None:
                    continue
                if Path(found.target).exists():
                    continue
                if not os.path.normcase(found.target).startswith(tuple(owned)):
                    continue
                if not self.should(entry, "Remove a link to a deleted skill"):
                    continue
                try:
                    remove_folder_link(entry)
                    self.status("REMOVED", f"Link to a deleted skill: {entry}")
                except OSError as error:
                    self.status("PROBLEM", f"Could not remove the stale link {entry}. {error}")

        # 6. Always-on rules: the operating rules from here, and the person's global rules from
        # dev-home. Claude Code loads every file in the rules folder of each Claude folder, where
        # each link is named dev-home- plus the folder it points to, since nothing there says
        # which repo a name belongs to. Codex reads one file, so setup writes the two joined.
        operating_rules = GENERATED_ROOT / "operating-rules"
        global_rules = global_rules_file.parent
        for claude_dir in claude_dirs:
            claude_name = Path(claude_dir).name
            rules = Path(claude_dir) / "rules"
            self.sync_link(
                rules / "dev-home-operating-rules",
                operating_rules,
                f"Claude Code operating rules in {claude_name}",
            )
            if global_rules.exists():
                self.sync_link(
                    rules / "dev-home-global-rules",
                    global_rules,
                    f"Claude Code global rules in {claude_name}",
                )
        if codex_installed:
            codex_note = generated.note(
                f"{forward(operating_template)} and {forward(global_rules_file)}",
                "Put rules of your own in the second file; changing the first changes "
                "dev-home-tools itself.",
            )
            self.sync_codex_rules(operating_template, global_rules_file, values, codex_note)

        # 7. Settings. A missing setting is offered as a change: shown first, made only after a
        # yes, and with a backup. See repair_setting.
        wanted_dirs = [comparable(content_root), comparable(TOOLS_ROOT)]
        for claude_dir in claude_dirs:
            self.check_claude_settings(Path(claude_dir), wanted_dirs, unlisted_claude_dir)
        if codex_installed:
            self.check_codex_config(comparable(content_root))

    def check_claude_settings(
        self, claude_dir: Path, wanted_dirs: list[str], unlisted_claude_dir: str | None
    ) -> None:
        claude_name = claude_dir.name
        path = claude_dir / "settings.json"
        present: list[str] = []
        if path.exists():
            try:
                text = path.read_bytes().decode("utf-8-sig", errors="replace")
            except OSError as error:
                self.status(
                    "PROBLEM",
                    f"{path} could not be read, so its settings were not checked. {error}",
                )
                return
            folders = claude_settings.folders_allowed(text)
            if folders is None:
                self.status(
                    "PROBLEM",
                    f"{path} could not be read as JSON, so its settings were not checked.",
                )
                return
            present = [comparable(resolve_home(folder, self.home)) for folder in folders]
        missing = [d for d in wanted_dirs if not any(same_path(d, p) for p in present)]
        if not missing:
            self.status(
                "OK",
                f"Claude Code settings in {claude_name}: additionalDirectories includes dev-home "
                "and dev-home-tools",
            )
            return
        try:
            plan = claude_settings.plan(path, missing)
        except Exception as error:
            plan = Plan(SettingsFile(), reason=f"planning the change failed ({describe(error)})")
        entries = ", ".join(claude_settings.dump(entry) for entry in missing)
        advice = QUIET_ADVICE
        if unlisted_claude_dir is not None and same_path(claude_dir, unlisted_claude_dir):
            if same_path(claude_dir.parent, self.home):
                list_entry = "~/" + claude_name
            else:
                list_entry = forward(claude_dir)
            advice = (
                "This folder comes only from CLAUDE_CONFIG_DIR, which a run without --quiet "
                f'usually doesn\'t have. Add "{list_entry}" to claudeConfigDirs in '
                f"{SETTINGS_PATH}, then run setup.py without --quiet, and it offers to make the "
                "change."
            )
        snippet = (
            "          {\n"
            '            "permissions": {\n'
            f'              "additionalDirectories": [{entries}]\n'
            "            }\n"
            "          }"
        )
        self.repair_setting(
            f"Claude Code settings in {claude_name}",
            path,
            f"{' and '.join(missing)} in permissions.additionalDirectories",
            plan,
            'Merge this into the file. If it already has "permissions", put '
            "additionalDirectories inside that block:",
            snippet,
            advice,
        )

    def check_codex_config(self, content_root: str) -> None:
        path = self.home / ".codex" / "config.toml"
        try:
            text = path.read_bytes().decode("utf-8-sig", errors="replace") if path.exists() else ""
        except OSError as error:
            self.status(
                "PROBLEM", f"{path} could not be read, so its settings were not checked. {error}"
            )
            return
        if codex_config.is_configured(text, content_root, CODEX_DOC_BYTES):
            self.status("OK", "Codex config: writable_roots and project_doc_max_bytes")
            return
        try:
            plan = codex_config.plan(path, content_root, CODEX_DOC_BYTES)
        except Exception as error:
            plan = Plan(SettingsFile(), reason=f"planning the change failed ({describe(error)})")
        snippet = (
            f"          project_doc_max_bytes = {CODEX_DOC_BYTES}\n\n"
            "          [sandbox_workspace_write]\n"
            f"          writable_roots = ['{content_root}']"
        )
        self.repair_setting(
            "Codex config",
            path,
            f"dev-home in writable_roots, and project_doc_max_bytes of at least {CODEX_DOC_BYTES} "
            "(Codex stops reading AGENTS.md files at 32 KiB by default)",
            plan,
            "Merge this into the file. project_doc_max_bytes goes above the first [section]. If "
            "the file already has [sandbox_workspace_write], add only the writable_roots line "
            "under it:",
            snippet,
        )


def make_writable(path: Path) -> None:
    """Clears the read-only mark from one of setup's own generated files, so it can be rewritten
    or removed."""
    if not os.access(path, os.W_OK):
        path.chmod(stat.S_IREAD | stat.S_IWRITE)


def remove_generated_file(path: Path) -> None:
    make_writable(path)
    path.unlink()


def linked_folder(destination: Path) -> Path | None:
    """The first folder that is a link, from destination up to the generated folder, or None."""
    root = os.path.normcase(comparable(GENERATED_ROOT))
    for folder in (destination, *destination.parents):
        full = os.path.normcase(comparable(folder))
        if full != root and not full.startswith(root + os.sep):
            return None
        if is_link(folder):
            return folder
    return None


def run_tool(program: str, *args: str) -> tuple[int, list[str]]:
    """Runs a program such as gh without printing its output. Returns the exit code and the
    output and error lines together."""
    done = subprocess.run(
        [program, *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    return done.returncode, done.stdout.splitlines()


def parse_arguments(argv: Sequence[str]) -> tuple[bool, bool, str] | str:
    """--quiet, --what-if, and --content-dir's folder, or why the arguments can't be used."""
    quiet = False
    what_if = False
    content_dir = ""
    rest = list(argv)
    while rest:
        word = rest.pop(0)
        if word == "--quiet":
            quiet = True
        elif word == "--what-if":
            what_if = True
        elif word == "--content-dir":
            if not rest:
                return "--content-dir needs a folder after it."
            content_dir = rest.pop(0)
        else:
            return f"No such option: {word}. The options are --quiet, --content-dir, and --what-if."
    return quiet, what_if, content_dir


def main(argv: Sequence[str]) -> int:
    if any(word in ("--help", "-h") for word in argv):
        print(__doc__)
        return 0
    parsed = parse_arguments(argv)
    if isinstance(parsed, str):
        status_line("PROBLEM", parsed)
        return 1
    quiet, what_if, content_dir = parsed
    # The sync runs this inside its own process, so nothing here may raise.
    try:
        run = Setup(quiet=quiet, what_if=what_if)
    except Exception as error:
        with contextlib.suppress(Exception):
            status_line("PROBLEM", f"setup.py stopped: {describe(error)}")
        return 1
    try:
        run.run(content_dir)
    except CannotGoOnError:
        pass
    except Exception as error:
        # Even this line may fail, such as when the output is closed.
        with contextlib.suppress(Exception):
            run.status("PROBLEM", f"setup.py stopped: {describe(error)}")
    try:
        return run.finish()
    except Exception:
        return 1
