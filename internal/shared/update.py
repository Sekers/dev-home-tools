"""Shows the dev-home-tools commits waiting on GitHub, and pulls them after a yes.

Lists each waiting commit and the files it changes, and points to the command that shows every
changed line. On a yes, it pulls them (fast-forward only), then runs setup so the updated
skills and rules take effect on this PC.

Everything about dev-home-tools updates happens here: a sync runs its quiet check, the same as
--quiet, and a person runs it without. So what the user is told and what gets installed come
from the same code.

Options:

    --quiet   What a sync runs, as quiet_check() inside its own process. Never asks. Checks
              GitHub, then prints at most one line, in the sync's format: OFFLINE when GitHub
              can't be reached, UPDATE while commits are waiting, or PULLED once it has pulled
              them, which it does only when autoUpdate is on in local-settings.json. Leaves setup
              to the sync, which runs it next.

Example, with Python 3.12 or later:

    py C:/Users/you/dev-home-tools/update.py

A sync loads this module only when it gets to the update check, and an error in it is reported
and can't stop the rest of the sync: an update is how fixes arrive.
"""

from collections.abc import Sequence

from .git import GIT_MISSING, run_git
from .output import CYAN, GREEN, RED, color, commit_count, first_line, status_line
from .programs import by_hand, find_program, run_setup
from .settings import TOOLS_ROOT, read_settings


def stop(quiet: bool, text: str) -> int:
    """With --quiet, a PROBLEM line, which the sync reports like its own."""
    if quiet:
        status_line("PROBLEM", text)
    else:
        print(color(text, RED), flush=True)
    return 1


def main(argv: Sequence[str]) -> int:
    quiet = False
    for word in argv:
        if word == "--quiet":
            quiet = True
        elif word in ("--help", "-h"):
            print(__doc__)
            return 0
        else:
            return stop(quiet, f"No such option: {word}. The only option is --quiet.")
    return quiet_check()[0] if quiet else ask_and_install()


def quiet_check() -> tuple[int, bool]:
    """What a sync runs: checks GitHub, never asks, and installs waiting commits only when
    autoUpdate is on. Returns the exit code, and whether it installed commits, since the sync's
    setup then needs the new code."""
    return check(quiet=True)


def ask_and_install() -> int:
    """What a person runs: shows the waiting commits, and installs them after a yes."""
    return check(quiet=False)[0]


def check(*, quiet: bool) -> tuple[int, bool]:
    # Git would otherwise use any repo this folder sits in, such as a zip download unpacked inside
    # another project, and offer to update that repo instead.
    if not (TOOLS_ROOT / ".git").exists():
        if quiet:
            return 0, False
        return stop(
            quiet,
            f"{TOOLS_ROOT} is not a git clone of dev-home-tools, so it can't update itself. Clone "
            "dev-home-tools as the README shows, and use that copy instead.",
        ), False

    if find_program("git") is None:
        return stop(quiet, f"dev-home-tools was not checked for updates. {GIT_MISSING}"), False

    # A clone with no upstream branch, such as a new local copy, has nothing to update from.
    if run_git(TOOLS_ROOT, "rev-parse", "--verify", "--quiet", "@{upstream}").code != 0:
        if quiet:
            return 0, False
        return stop(quiet, "This clone has no upstream branch to update from."), False

    fetch = run_git(TOOLS_ROOT, "fetch", "--quiet")
    if fetch.code != 0:
        if quiet:
            status_line(
                "OFFLINE",
                f"Could not check dev-home-tools for updates. git: {first_line(fetch.err)}",
            )
            return 0, False
        problem = f"Could not reach GitHub. git: {first_line(fetch.err + fetch.out)}"
        return stop(quiet, problem), False

    # Everything below uses this exact commit, not @{upstream}: a sync in another session can
    # fetch newer commits while the question waits, and a yes pulls only what was shown.
    target = run_git(TOOLS_ROOT, "rev-parse", "--verify", "--quiet", "@{upstream}")
    if target.code != 0:
        return stop(
            quiet,
            "Could not read what GitHub has for dev-home-tools. "
            f"git: {first_line(target.err + target.out)}",
        ), False
    commit = target.text.strip()

    counts = run_git(TOOLS_ROOT, "rev-list", "--left-right", "--count", f"HEAD...{commit}")
    parts = counts.text.split()
    if counts.code != 0 or len(parts) != 2:
        return stop(
            quiet,
            "Could not compare dev-home-tools with GitHub. "
            f"git: {first_line(counts.err + counts.out)}",
        ), False
    ahead, behind = int(parts[0]), int(parts[1])
    if behind == 0:
        if not quiet:
            print(color("dev-home-tools is up to date.", GREEN), flush=True)
        return 0, False
    waiting = commit_count(behind)
    if ahead > 0:
        if quiet:
            status_line(
                "UPDATE",
                f"{waiting} waiting in dev-home-tools, not installed, because this clone has "
                f"{commit_count(ahead)} of its own. The user can merge them by hand.",
            )
            return 0, False
        return stop(
            quiet,
            f"This clone has {commit_count(ahead)} of its own, so it can't simply move forward to "
            f"the {waiting} on GitHub. Merge them by hand.",
        ), False

    if quiet:
        # Only the user's own setting installs anything unasked. A file that can't be read counts
        # as autoUpdate off.
        settings = read_settings() or {}
        if settings.get("autoUpdate") is not True:
            status_line(
                "UPDATE",
                f"{waiting} waiting in dev-home-tools. To see them and install them, the user "
                f"runs: {by_hand('update.py')}",
            )
            return 0, False
        merge = run_git(TOOLS_ROOT, "merge", "--ff-only", "--quiet", commit)
        if merge.code != 0:
            status_line(
                "UPDATE",
                f"{waiting} waiting in dev-home-tools, not installed. "
                f"git: {first_line(merge.err + merge.out)}",
            )
            return 0, False
        status_line("PULLED", f"{waiting} to dev-home-tools.")
        return 0, True

    print(f"{waiting} waiting in dev-home-tools:")
    print()
    log = run_git(TOOLS_ROOT, "log", "--format=  %h %ad  %s", "--date=short", f"HEAD..{commit}")
    for line in log.out:
        print(line)
    print()
    print("Files they change:")
    for line in run_git(TOOLS_ROOT, "diff", "--stat", "HEAD", commit).out:
        print("  " + line)
    print()
    print(f"To see every changed line first: git -C {TOOLS_ROOT.as_posix()} diff HEAD {commit}")
    print(flush=True)

    try:
        answer = input("Pull them now? [y/N] ")
    except EOFError:
        no_answer = "No answer came, so nothing was pulled. Run it in a terminal to answer."
        return stop(quiet, no_answer), False
    if answer.strip().lower() not in ("y", "yes"):
        print("Nothing was pulled.")
        return 0, False

    merge = run_git(TOOLS_ROOT, "merge", "--ff-only", "--quiet", commit)
    if merge.code != 0:
        problem = f"Could not pull them. git: {first_line(merge.err + merge.out)}"
        return stop(quiet, problem), False
    print(color(f"Pulled {waiting}. Running setup so they take effect:", CYAN), flush=True)
    # The code just pulled is new, so setup runs in a process of its own to load it.
    if not run_setup(fresh=True):
        return 1, True
    print(color("Done.", GREEN))
    return 0, True
