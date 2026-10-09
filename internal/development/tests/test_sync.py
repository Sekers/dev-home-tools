"""sync.py and update.py, run from a sandbox's copy as a person or a skill runs them.

The sandbox's copy of this repo is a git clone with a remote, as a person's is, and a second
clone of that remote stands in for the maintainer pushing updates. The tests run in order and
share the sandbox, so each one starts from where the one before it left off.
"""

import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import IO

import pytest

from helpers import (
    Run,
    Sandbox,
    finish,
    git,
    link_target,
    run,
    run_python,
    run_while_asking,
    sandbox_for,
    shared_module,
    start_python,
    write_text,
)

if sys.platform == "win32":
    import msvcrt
else:
    import fcntl

pytestmark = pytest.mark.xdist_group("sync")

DEMO = "handoffs/demo/HANDOFF.md"
FRESH_SETUP_LINE = "Setup ran with the new code."


@pytest.fixture(scope="module")
def box(request: pytest.FixtureRequest) -> Iterator[Sandbox]:
    for sandbox in sandbox_for(request, "sync", tools_repo=True):
        # Most tests here push an update and expect the next sync to find it, so the update check
        # fetches every time. The tests of its interval set their own.
        set_setting(sandbox, "updateCheckHours", 0)
        yield sandbox


def sync(box: Sandbox, *args: str) -> Run:
    return run_python(box, "sync.py", *args)


def append(path: Path, text: str) -> None:
    with path.open("a", encoding="utf-8", newline="\n") as file:
        file.write(text + "\n")


def generated_skill(box: Sandbox) -> str:
    return (box.generated / "skills" / "handoff" / "SKILL.md").read_text(encoding="utf-8")


def push_update(box: Sandbox, line: str) -> None:
    """The maintainer pushes a change to the handoff skill."""
    append(box.upstream / "templates" / "skills" / "handoff" / "SKILL.md", line)
    git("-C", str(box.upstream), "commit", "--quiet", "-am", f"handoff: {line}")
    git("-C", str(box.upstream), "push", "--quiet")


def make_setup_require_fresh_output(shared: Path) -> None:
    """Changes setup and output together so setup only loads when both modules are new."""
    append(shared / "output.py", f'FRESH = "{FRESH_SETUP_LINE}"')
    setup = shared / "setup.py"
    text = setup.read_text(encoding="utf-8")
    text = text.replace("from .output import GREEN,", "from .output import FRESH, GREEN,", 1)
    main = "def main(argv: Sequence[str]) -> int:\n"
    text = text.replace(main, main + "    print(FRESH)\n", 1)
    assert text.count("FRESH") == 2
    write_text(setup, text)


def set_setting(box: Sandbox, key: str, value: object) -> None:
    """Sets one key in the sandbox's local-settings.json, or removes it when value is None."""
    path = box.tools / "local-settings.json"
    settings = json.loads(path.read_text(encoding="utf-8"))
    if value is None:
        settings.pop(key, None)
    else:
        settings[key] = value
    write_text(path, json.dumps(settings, indent=2) + "\n")


def set_auto_update(box: Sandbox, on: bool) -> None:
    set_setting(box, "autoUpdate", on)


def count(result: Run, pattern: str) -> int:
    return sum(1 for line in result.lines if re.search(pattern, line))


def other_pc(box: Sandbox) -> Path:
    """Another PC's dev-home, up to date with GitHub."""
    other = box.root / "other-pc"
    if other.exists():
        git("-C", str(other), "pull", "--quiet", "--ff-only")
    else:
        git("clone", "--quiet", str(box.remote), str(other))
    return other


def push_from(repo: Path, relative: str, message: str) -> None:
    git("-C", str(repo), "add", "--", relative)
    git("-C", str(repo), "commit", "--quiet", "-m", message)
    git("-C", str(repo), "push", "--quiet")


@contextlib.contextmanager
def hook(repo_git_dir: Path, name: str, script: str) -> Iterator[None]:
    """A git hook for the length of the block, which git runs with its own sh on Windows too.
    The repo's own config names its hooks folder, in case the user's global config names
    another."""
    path = repo_git_dir / "hooks" / name
    write_text(path, "#!/bin/sh\n" + script)
    hooks = (repo_git_dir / "hooks").as_posix()
    git("--git-dir", str(repo_git_dir), "config", "core.hooksPath", hooks)
    try:
        yield
    finally:
        path.unlink()
        git("--git-dir", str(repo_git_dir), "config", "--unset", "core.hooksPath")


def test_a_plain_sync_says_dev_home_is_up_to_date(box: Sandbox) -> None:
    result = sync(box)
    assert result.code == 0, str(result)
    assert result.has_line(r"^OK\s+dev-home is up to date with GitHub\."), str(result)
    assert not result.has_line(r"^(UPDATE|PROBLEM)\s"), str(result)


def test_the_skills_commit_command_runs_as_written(box: Sandbox) -> None:
    # Every command in the skills that commits starts the same way: the Python link, -I,
    # sync.py, and --message. Once, it runs through the link, with a message and a path.
    prefix = f"{box.python.as_posix()} -I {(box.tools / 'sync.py').as_posix()} --message "
    for skill in ("handoff", "knowledge"):
        text = (box.generated / "skills" / skill / "SKILL.md").read_text(encoding="utf-8")
        commands = re.findall(r"`([^`]*/sync\.py --message [^`]*)`", text)
        assert commands, f"{skill} gives no command that commits"
        assert all(c.startswith(prefix) for c in commands), commands
    append(box.content / DEMO, "Committed through the Python link.")
    argv = [str(box.python), "-I", str(box.tools / "sync.py"), "--message", "handoff: demo", DEMO]
    result = run(box, argv, cwd=box.root)
    assert result.code == 0, str(result)
    assert result.has_line(r'^COMMITTED\s+"handoff: demo" \(handoffs/demo/HANDOFF\.md\)'), str(
        result
    )


def test_a_sync_that_commits_with_nothing_new_leaves_setup_to_the_next_plain_sync(
    box: Sandbox,
) -> None:
    # A skill of the user's own, created on this PC after setup ran.
    later = box.content / "skills" / "later"
    write_text(later / "SKILL.md", "---\nname: later\ndescription: Added after setup.\n---\n")
    append(box.content / DEMO, "Before the new skill is linked.")
    result = sync(box, "--message", "handoff: demo", DEMO)
    assert result.code == 0, str(result)
    assert result.has_line(r"^COMMITTED\s"), str(result)
    assert link_target(box.profile / ".claude" / "skills" / "later") is None, str(result)
    sync(box)
    assert link_target(box.profile / ".claude" / "skills" / "later") == later
    (later / "SKILL.md").unlink()
    later.rmdir()


def test_commits_and_pushes_only_the_named_file_and_lists_the_other_as_left(
    box: Sandbox,
) -> None:
    append(box.content / DEMO, "A new line.")
    write_text(box.content / "notes.md", "someone else's file\n")
    try:
        result = sync(box, "--message", "handoff: demo", DEMO)
        pushed = git("-C", str(box.remote), "log", "-1", "--format=%s", "main")
        untracked = git("-C", str(box.content), "status", "--porcelain")
    finally:
        (box.content / "notes.md").unlink()
    assert result.code == 0, str(result)
    assert pushed == ["handoff: demo"], pushed
    assert "?? notes.md" in untracked, untracked
    assert result.has_line(r"^LEFT\s+notes\.md \(new file, under a minute ago\)"), str(result)


def test_passes_on_an_accented_letter_in_a_file_name_as_it_is(box: Sandbox) -> None:
    accented = box.content / "notes-été.md"
    write_text(accented, "a summer note\n")
    try:
        result = sync(box)
    finally:
        accented.unlink()
    assert result.has_line("^LEFT\\s+notes-été\\.md "), str(result)


def test_a_file_deleted_with_its_folder_is_left_dated_by_the_folder_above(box: Sandbox) -> None:
    # A committed file deleted just now along with its folder, which leaves no time of its own.
    write_text(box.content / "archive" / "old-note.md", "an old note\n")
    git("-C", str(box.content), "add", "--", "archive/old-note.md")
    git("-C", str(box.content), "commit", "--quiet", "-m", "archive: old note")
    git("-C", str(box.content), "push", "--quiet")
    (box.content / "archive" / "old-note.md").unlink()
    (box.content / "archive").rmdir()
    result = sync(box)
    git("-C", str(box.content), "add", "--", "archive/old-note.md")
    git("-C", str(box.content), "commit", "--quiet", "-m", "archive: remove old note")
    git("-C", str(box.content), "push", "--quiet")
    pattern = r"^LEFT\s+archive/old-note\.md \(deleted, under a minute ago\)"
    assert result.has_line(pattern), str(result)


def test_a_sync_that_commits_and_brings_in_commits_runs_setup(box: Sandbox) -> None:
    # Another PC pushes a new skill. A sync that commits brings it in, so it runs setup as well.
    other = other_pc(box)
    write_text(
        other / "skills" / "from-other-pc" / "SKILL.md",
        "---\nname: from-other-pc\ndescription: Pushed from another PC.\n---\n",
    )
    push_from(other, "skills/from-other-pc/SKILL.md", "skills: from another PC")
    append(box.content / DEMO, "While another PC pushed.")
    result = sync(box, "--message", "handoff: demo", DEMO)
    assert result.code == 0, str(result)
    # Both PCs had new commits.
    assert result.has_line(r"^MERGED\s+1 commit from GitHub, with a merge commit"), str(result)
    assert result.has_line(r"^PUSHED\s+2 commits to GitHub\."), str(result)
    assert link_target(box.profile / ".claude" / "skills" / "from-other-pc") is not None


def test_waits_out_another_git_process_lock_then_commits(box: Sandbox) -> None:
    lock = box.content / ".git" / "index.lock"
    write_text(lock, "")
    release = threading.Timer(1.0, lock.unlink)
    release.start()
    append(box.content / DEMO, "While git was busy.")
    try:
        result = sync(box, "--message", "handoff: demo", DEMO)
    finally:
        release.join()
    assert result.code == 0, str(result)
    assert result.has_line(r"^COMMITTED\s"), str(result)


def hold(handle: IO[bytes]) -> None:
    handle.seek(0)
    if sys.platform == "win32":
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
    else:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)


def let_go(handle: IO[bytes]) -> None:
    handle.seek(0)
    if sys.platform == "win32":
        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def test_waits_for_another_sync_on_the_same_dev_home_to_finish(box: Sandbox) -> None:
    # While another run holds the lock, a sync that commits hasn't committed, however long it
    # takes; once the lock goes, it does.
    head = git("-C", str(box.content), "rev-parse", "HEAD")
    append(box.content / DEMO, "Committed once the other run let go.")
    with (box.content / ".git" / "dev-home-sync.lock").open("a+b") as handle:
        hold(handle)
        process = start_python(box, "sync.py", "--message", "handoff: demo", DEMO)
        try:
            time.sleep(3)
            still_running = process.poll() is None
            head_while_held = git("-C", str(box.content), "rev-parse", "HEAD")
        finally:
            let_go(handle)
        result = finish(process)
    assert still_running, str(result)
    assert head_while_held == head, "it committed while another run held the lock"
    assert result.code == 0, str(result)
    assert result.has_line(r"^COMMITTED\s"), str(result)


def test_a_lock_it_cant_take_is_reported_at_once(box: Sandbox) -> None:
    # Here, a folder where the lock file goes, so the file can't be opened. A file system with
    # no locks gives the same line.
    lock = box.content / ".git" / "dev-home-sync.lock"
    lock.unlink()
    lock.mkdir()
    started = time.monotonic()
    try:
        result = sync(box)
    finally:
        lock.rmdir()
    assert time.monotonic() - started < 60, "it waited as if another sync were running"
    assert result.code == 1, str(result)
    pattern = (
        r"^PROBLEM\s+Nothing was synced: each sync holds a lock on a file.*could not be opened"
    )
    assert result.has_line(pattern), str(result)


def test_with_auto_update_off_reports_a_waiting_update_and_pulls_nothing(box: Sandbox) -> None:
    push_update(box, "Upstream change one.")
    result = sync(box)
    assert result.code == 0, str(result)
    command = f"py {(box.tools / 'update.py').as_posix()}"
    if sys.platform != "win32":
        command = f"python3 {(box.tools / 'update.py').as_posix()}"
    pattern = rf"^UPDATE\s+1 commit waiting.*the user runs: {re.escape(command)}$"
    assert result.has_line(pattern), str(result)
    assert "Upstream change one." not in generated_skill(box)


def test_a_sync_that_commits_skips_the_update_check(box: Sandbox) -> None:
    # The plain sync before it just made the check.
    append(box.content / DEMO, "While an update waits.")
    result = sync(box, "--message", "handoff: demo", DEMO)
    assert result.code == 0, str(result)
    assert result.has_line(r"^COMMITTED\s"), str(result)
    assert not result.has_line(r"^UPDATE\s"), str(result)


def test_with_auto_update_on_pulls_the_update_and_sets_it_up(box: Sandbox) -> None:
    set_auto_update(box, True)
    try:
        result = sync(box)
    finally:
        set_auto_update(box, False)
    assert result.code == 0, str(result)
    assert result.has_line(r"^PULLED\s+1 commit to dev-home-tools\."), str(result)
    assert "Upstream change one." in generated_skill(box)


def test_with_auto_update_on_never_overwrites_a_local_edit(box: Sandbox) -> None:
    push_update(box, "Upstream change one-b.")
    local = box.tools / "templates" / "skills" / "handoff" / "SKILL.md"
    before = local.read_bytes()
    append(local, "A local edit.")
    set_auto_update(box, True)
    try:
        # The edit goes before the second sync, which then installs the update over the file.
        try:
            result = sync(box)
            edited = local.read_text(encoding="utf-8")
        finally:
            local.write_bytes(before)
        after = sync(box)
    finally:
        set_auto_update(box, False)
    assert result.code == 0, str(result)
    assert result.has_line(r"^UPDATE\s.*not installed"), str(result)
    assert "A local edit." in edited
    assert after.has_line(r"^PULLED\s"), str(after)
    assert "Upstream change one-b." in generated_skill(box)


def test_setup_after_an_update_runs_the_new_code(box: Sandbox) -> None:
    # The update changes two modules, the second needing the first. The sync loaded the old
    # output.py before it pulled, so setup must run as a process of its own to get the new pair.
    shared = box.upstream / "internal" / "shared"
    make_setup_require_fresh_output(shared)
    git("-C", str(box.upstream), "commit", "--quiet", "-am", "setup: say it runs the new code")
    git("-C", str(box.upstream), "push", "--quiet")
    set_auto_update(box, True)
    try:
        result = sync(box)
    finally:
        git("-C", str(box.upstream), "revert", "--no-edit", "HEAD")
        git("-C", str(box.upstream), "push", "--quiet")
        sync(box)
        set_auto_update(box, False)
    assert result.code == 0, str(result)
    assert result.has_line(r"^PULLED\s+1 commit to dev-home-tools\."), str(result)
    assert result.has_line(rf"^{re.escape(FRESH_SETUP_LINE)}$"), str(result)


def test_setup_after_waiting_for_an_update_in_another_sync_runs_fresh_code(
    box: Sandbox,
) -> None:
    # This sync loads the shared modules, then waits for another sync. The other sync can update
    # those files before it releases the lock, so setup must not combine the loaded old modules
    # with new setup.py from disk.
    shared = box.tools / "internal" / "shared"
    programs = shared / "programs.py"
    output = shared / "output.py"
    setup = shared / "setup.py"
    originals = {path: path.read_text(encoding="utf-8") for path in (programs, output, setup)}
    loaded = box.root / "waiting-sync-loaded-programs"
    marker = f'Path(r"{loaded}").write_text("loaded", encoding="utf-8")\n'
    programs_text = originals[programs]
    snapshot = "_LOADED_SHARED_FILE_TIMES = _shared_file_times()\n"
    programs_text = programs_text.replace(snapshot, snapshot + marker, 1)
    assert programs_text.count(marker) == 1
    write_text(programs, programs_text)

    process: subprocess.Popen[bytes] | None = None
    try:
        with (box.content / ".git" / "dev-home-sync.lock").open("a+b") as handle:
            hold(handle)
            process = start_python(box, "sync.py")
            try:
                deadline = time.monotonic() + 10
                while (
                    not loaded.exists() and process.poll() is None and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                assert loaded.exists(), "the waiting sync did not finish loading its modules"
                make_setup_require_fresh_output(shared)
            finally:
                let_go(handle)
        result = finish(process)
        process = None
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
            finish(process)
        for path, text in originals.items():
            write_text(path, text)
        loaded.unlink(missing_ok=True)

    assert result.code == 0, str(result)
    assert result.has_line(rf"^{re.escape(FRESH_SETUP_LINE)}$"), str(result)


def test_update_with_nothing_waiting_says_so(box: Sandbox) -> None:
    result = run_python(box, "update.py")
    assert result.code == 0, str(result)
    assert result.has_line("dev-home-tools is up to date"), str(result)


def test_a_broken_update_is_reported_and_setup_still_runs_after_it(box: Sandbox) -> None:
    # An update is how fixes arrive, so even an update.py that can't load can't stop the sync.
    push_update(box, "Upstream change two.")
    update = box.tools / "internal" / "shared" / "update.py"
    before = update.read_bytes()
    write_text(update, "raise RuntimeError('broken on purpose')\n")
    probe = box.content / "skills" / "probe"
    write_text(probe / "SKILL.md", "---\nname: probe\ndescription: For this check.\n---\n")
    try:
        result = sync(box)
    finally:
        update.write_bytes(before)
        (probe / "SKILL.md").unlink()
        probe.rmdir()
    assert result.code == 1, str(result)
    pattern = r"^PROBLEM\s+update\.py stopped: RuntimeError: broken on purpose"
    assert result.has_line(pattern), str(result)
    assert link_target(box.profile / ".claude" / "skills" / "probe") is not None, str(result)


def test_update_shows_the_waiting_commit_and_a_no_pulls_nothing(box: Sandbox) -> None:
    result = run_python(box, "update.py", answer="n")
    assert result.code == 0, str(result)
    assert result.has_line(r"handoff: Upstream change two\."), str(result)
    assert result.has_line("Nothing was pulled"), str(result)
    assert "Upstream change two." not in generated_skill(box)


def test_update_with_no_answer_pulls_nothing(box: Sandbox) -> None:
    result = run_python(box, "update.py")
    assert result.code == 1, str(result)
    assert result.has_line("No answer came, so nothing was pulled"), str(result)
    assert "Upstream change two." not in generated_skill(box)


def test_update_with_a_yes_pulls_and_sets_it_up(box: Sandbox) -> None:
    result = run_python(box, "update.py", answer="y")
    assert result.code == 0, str(result)
    assert "Upstream change two." in generated_skill(box)


def test_update_pulls_only_the_commits_it_showed(box: Sandbox) -> None:
    # A sync in another session fetches a newer commit while update.py waits for its answer.
    push_update(box, "Upstream change three.")

    def newer_commit_arrives() -> None:
        push_update(box, "Upstream change four.")
        git("-C", str(box.tools), "fetch", "--quiet")

    result = run_while_asking(
        box,
        "update.py",
        prompt=r"^To see every changed line first",
        answer="y",
        meanwhile=newer_commit_arrives,
    )
    head = git("-C", str(box.tools), "log", "-1", "--format=%s")
    skill = generated_skill(box)
    assert result.code == 0, str(result)
    assert head == ["handoff: Upstream change three."], head
    assert "Upstream change three." in skill
    assert "Upstream change four." not in skill


def test_with_commits_of_its_own_the_notice_says_to_merge_by_hand(box: Sandbox) -> None:
    # A clone with a commit of its own can't simply move forward, and update.py would refuse.
    write_text(box.tools / "local-note.md", "a local change\n")
    git("-C", str(box.tools), "add", "--", "local-note.md")
    git("-C", str(box.tools), "commit", "--quiet", "-m", "local: note")
    try:
        result = sync(box)
    finally:
        git("-C", str(box.tools), "reset", "--quiet", "--hard", "HEAD~1")
    assert result.code == 0, str(result)
    assert result.has_line(r"^UPDATE\s.*merge them by hand"), str(result)
    assert not result.has_line(r"update\.py"), str(result)


def test_when_dev_home_tools_cant_be_checked_says_offline_for_it_alone(box: Sandbox) -> None:
    url = git("-C", str(box.tools), "remote", "get-url", "origin")[0]
    git("-C", str(box.tools), "remote", "set-url", "origin", str(box.root / "missing.git"))
    try:
        result = sync(box)
    finally:
        git("-C", str(box.tools), "remote", "set-url", "origin", url)
    assert result.code == 0, str(result)
    assert result.has_line(r"^OFFLINE\s.*dev-home-tools"), str(result)
    assert count(result, r"^OFFLINE\s") == 1, str(result)


def test_when_dev_home_cant_be_synced_its_offline_line_names_dev_home(box: Sandbox) -> None:
    url = git("-C", str(box.content), "remote", "get-url", "origin")[0]
    git("-C", str(box.content), "remote", "set-url", "origin", str(box.root / "missing.git"))
    try:
        result = sync(box)
    finally:
        git("-C", str(box.content), "remote", "set-url", "origin", url)
    assert result.code == 0, str(result)
    assert result.has_line(r"^OFFLINE\s+Could not reach GitHub, so dev-home may be behind"), str(
        result
    )
    assert count(result, r"^OFFLINE\s") == 1, str(result)


def test_a_tooling_clone_with_no_upstream_is_skipped_quietly(box: Sandbox) -> None:
    git("-C", str(box.tools), "branch", "--quiet", "--unset-upstream")
    try:
        result = sync(box)
    finally:
        git("-C", str(box.tools), "branch", "--quiet", "--set-upstream-to=origin/main")
    assert result.code == 0, str(result)
    assert not result.has_line(r"^(UPDATE|OFFLINE)\s"), str(result)


@pytest.mark.parametrize(
    ("args", "says"),
    [
        (["--message", "no area", DEMO], r"<area>: <what>"),
        (["--message", "handoff: demo", "handoffs"], r"is a folder"),
        (["--message", "handoff: demo", "../outside.md"], r"not inside dev-home"),
        (["--message", "handoff: demo"], r"Name the files to commit after --message"),
        ([DEMO], r'Give a commit message with --message "<area>: <what>"'),
        (["--message"], r"--message needs the commit message after it"),
        (["--mess", "handoff: demo", DEMO], r"No such option: --mess"),
        (["--fetch"], r"--fetch needs one of these after it: always, auto, when-due"),
        (["--fetch", "sometimes"], r"--fetch needs one of these after it"),
        (["--fetch", "auto", "--message", "handoff: demo", DEMO], r"--fetch is for a sync"),
    ],
)
def test_refuses_arguments_it_cant_use(box: Sandbox, args: list[str], says: str) -> None:
    result = sync(box, *args)
    assert result.code == 1, str(result)
    assert result.has_line(rf"^PROBLEM\s.*{says}"), str(result)
    assert not result.has_line(r"^(COMMITTED|OK)\s"), str(result)


def test_help_says_how_to_commit(box: Sandbox) -> None:
    result = sync(box, "--help")
    assert result.code == 0, str(result)
    assert result.has_line(r"--message"), str(result)


def test_without_local_settings_says_to_run_setup(box: Sandbox) -> None:
    settings = box.tools / "local-settings.json"
    hidden = settings.with_name("local-settings.json.off")
    settings.rename(hidden)
    try:
        result = sync(box)
    finally:
        hidden.rename(settings)
    assert result.code == 1, str(result)
    assert result.has_line(r"^PROBLEM\s+dev-home-tools is not set up on this PC"), str(result)


def test_update_in_a_copy_that_is_not_a_git_clone_stops_before_running_git(box: Sandbox) -> None:
    # Git would otherwise use the repo around the copy. The tests' ceiling is a second guard.
    dot_git = box.tools / ".git"
    hidden = box.tools / ".git-off"
    dot_git.rename(hidden)
    try:
        result = run_python(box, "update.py")
    finally:
        hidden.rename(dot_git)
    assert result.code == 1, str(result)
    assert result.has_line("not a git clone"), str(result)


# Keeping dev-home safe: what a sync does when git can't simply go ahead.


def test_when_two_pcs_change_the_same_lines_the_merge_is_undone(box: Sandbox) -> None:
    other = other_pc(box)
    write_text(other / "notes" / "shared.md", "from the other PC\n")
    push_from(other, "notes/shared.md", "notes: from the other PC")
    write_text(box.content / "notes" / "shared.md", "from this PC\n")
    try:
        result = sync(box, "--message", "notes: from this PC", "notes/shared.md")
        merging = (box.content / ".git" / "MERGE_HEAD").exists()
        mine = (box.content / "notes" / "shared.md").read_text(encoding="utf-8")
    finally:
        git("-C", str(box.content), "reset", "--quiet", "--hard", "@{upstream}")
    assert result.code == 1, str(result)
    assert result.has_line(r"^COMMITTED\s"), str(result)
    pattern = r"^PROBLEM\s+Two PCs changed notes/shared\.md\. The merge was undone"
    assert result.has_line(pattern), str(result)
    pending = r"^PENDING\s+1 commit saved on this PC, not synced to GitHub yet\. The next sync "
    assert result.has_line(pending + r"sends it\.$"), str(result)
    assert not merging, "a merge is still in progress"
    assert mine == "from this PC\n"


def test_an_uncommitted_change_blocks_a_pull_that_would_change_it(box: Sandbox) -> None:
    other = other_pc(box)
    append(other / DEMO, "From the other PC.")
    push_from(other, DEMO, "handoff: demo from the other PC")
    append(box.content / DEMO, "Not committed here.")
    try:
        result = sync(box)
        mine = (box.content / DEMO).read_text(encoding="utf-8")
    finally:
        git("-C", str(box.content), "checkout", "--quiet", "--", DEMO)
        sync(box)
    assert result.code == 1, str(result)
    pattern = (
        r"^PROBLEM\s+Git won't bring in the commits from GitHub while these files have "
        r"uncommitted changes here: handoffs/demo/HANDOFF\.md\. Nothing was changed\."
    )
    assert result.has_line(pattern), str(result)
    assert mine.endswith("Not committed here.\n")


def test_a_commit_git_refuses_is_reported_and_the_file_left_unstaged(box: Sandbox) -> None:
    append(box.content / DEMO, "A commit the hook refuses.")
    try:
        with hook(box.content / ".git", "pre-commit", "echo 'refused on purpose' >&2\nexit 1\n"):
            result = sync(box, "--message", "handoff: demo", DEMO)
        status = git("-C", str(box.content), "status", "--porcelain")
    finally:
        git("-C", str(box.content), "checkout", "--quiet", "--", DEMO)
    assert result.code == 1, str(result)
    pattern = r"^PROBLEM\s+Could not commit handoffs/demo/HANDOFF\.md\. git: refused on purpose"
    assert result.has_line(pattern), str(result)
    # Changed, but no longer staged, since git refuses to merge while anything is.
    assert status == [" M handoffs/demo/HANDOFF.md"], status


def test_a_push_github_rejects_gets_one_more_round(box: Sandbox) -> None:
    marker = box.root / "rejected-once"
    script = (
        f"if [ ! -f '{marker.as_posix()}' ]; then\n"
        f"  touch '{marker.as_posix()}'\n  echo 'rejected on purpose' >&2\n  exit 1\nfi\n"
    )
    append(box.content / DEMO, "Pushed on the second round.")
    with hook(box.remote, "pre-receive", script):
        result = sync(box, "--message", "handoff: demo", DEMO)
    assert marker.exists(), "GitHub never rejected the first push"
    assert result.code == 0, str(result)
    assert result.has_line(r"^PUSHED\s+1 commit to GitHub\."), str(result)
    assert not result.has_line(r"^PENDING\s"), str(result)


def test_offline_a_commit_waits_and_the_next_sync_pushes_it(box: Sandbox) -> None:
    url = git("-C", str(box.content), "remote", "get-url", "origin")[0]
    git("-C", str(box.content), "remote", "set-url", "origin", str(box.root / "missing.git"))
    append(box.content / DEMO, "Committed while offline.")
    try:
        result = sync(box, "--message", "handoff: demo", DEMO)
    finally:
        git("-C", str(box.content), "remote", "set-url", "origin", url)
    assert result.code == 0, str(result)
    assert result.has_line(r"^COMMITTED\s"), str(result)
    # A commit pushes first, and a push that fails without being rejected isn't tried again.
    assert not result.has_line(r"^OFFLINE\s"), str(result)
    pattern = (
        r"^PENDING\s+1 commit saved on this PC, not synced to GitHub yet\. The next sync sends "
        r"it\. git: \S"
    )
    assert result.has_line(pattern), str(result)
    result = sync(box)
    assert result.has_line(r"^PUSHED\s+1 commit to GitHub\."), str(result)


def test_a_file_nobody_has_touched_for_15_minutes_is_stale(box: Sandbox) -> None:
    draft = box.content / "old-draft.md"
    write_text(draft, "a draft\n")
    then = time.time() - 20 * 60
    os.utime(draft, (then, then))
    try:
        result = sync(box)
    finally:
        draft.unlink()
    assert result.has_line(r"^STALE\s+old-draft\.md \(new file, 20 min ago\)"), str(result)


def test_lists_a_staged_rename_with_its_old_name(box: Sandbox) -> None:
    content = str(box.content)
    git("-C", content, "mv", "knowledge/README.md", "knowledge/INDEX.md")
    try:
        result = sync(box)
    finally:
        git("-C", content, "mv", "knowledge/INDEX.md", "knowledge/README.md")
    pattern = r"^(LEFT|STALE)\s+knowledge/INDEX\.md \(renamed from knowledge/README\.md, staged, "
    assert result.has_line(pattern), str(result)


def test_stops_while_a_merge_is_in_progress(box: Sandbox) -> None:
    marker = box.content / ".git" / "MERGE_HEAD"
    write_text(marker, git("-C", str(box.content), "rev-parse", "HEAD")[0] + "\n")
    try:
        result = sync(box)
    finally:
        marker.unlink()
    assert result.code == 1, str(result)
    assert result.has_line(r"^PROBLEM\s+A merge is in progress in dev-home"), str(result)
    assert not result.has_line(r"^OK\s"), str(result)


def test_without_git_in_path_says_so_and_runs_nothing_named_git(box: Sandbox) -> None:
    # A bare "git" could start a program of that name in the current folder, a project's.
    folders = os.environ["PATH"].split(os.pathsep)
    path = os.pathsep.join(f for f in folders if not shutil.which("git", path=f))
    result = run_python(box, "sync.py", env={"PATH": path})
    assert result.code == 1, str(result)
    assert result.has_line(r"^PROBLEM\s+dev-home was not synced\. Git was not found in PATH"), str(
        result
    )
    result = run_python(box, "update.py", env={"PATH": path})
    assert result.code == 1, str(result)
    assert result.has_line("dev-home-tools was not checked for updates. Git was not found"), str(
        result
    )


@pytest.mark.skipif(sys.platform != "win32", reason="only Windows file names ignore case")
def test_two_spellings_of_one_file_are_committed_once(box: Sandbox) -> None:
    append(box.content / DEMO, "Named twice.")
    other_spelling = str(box.content / "HANDOFFS" / "demo" / "handoff.md")
    result = sync(box, "--message", "handoff: demo", DEMO, other_spelling)
    assert result.code == 0, str(result)
    assert result.has_line(r'^COMMITTED\s+"handoff: demo" \(handoffs/demo/HANDOFF\.md\)$'), str(
        result
    )


def test_quotes_gits_reason_not_a_warning_before_it(box: Sandbox) -> None:
    first_line = shared_module(box, "output").first_line
    assert first_line(["warning: LF will be replaced by CRLF", "fatal: the reason"]) == (
        "fatal: the reason"
    )
    assert first_line(["", "hint: a hint", "  error: why  "]) == "error: why"
    assert first_line(["warning: nothing else"]) == "warning: nothing else"
    assert first_line([]) == "(no message)"


def test_after_waiting_its_limit_for_another_sync_says_so(
    box: Sandbox, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # The limit is 2 minutes, so this runs the sync's code here, with a limit of 1 second.
    code = shared_module(box, "sync")
    monkeypatch.setattr(code, "LOCK_WAIT_SECONDS", 1)
    with (box.content / ".git" / "dev-home-sync.lock").open("a+b") as handle:
        hold(handle)
        try:
            returned = code.main([])
        finally:
            let_go(handle)
    out = capsys.readouterr().out
    assert returned == 1, out
    assert re.search(r"^PROBLEM\s+Another sync in dev-home has been running for ", out, re.M), out
    assert not re.search(r"^(OK|LEFT|UPDATE)\s", out, re.M), out


# A bug can't stop the update that would fix it.


def test_an_error_in_one_step_still_lets_the_update_check_and_setup_run(
    box: Sandbox, monkeypatch: pytest.MonkeyPatch, capfd: pytest.CaptureFixture[str]
) -> None:
    # An update is waiting (the maintainer's change four), so the update check reports it.
    code = shared_module(box, "sync")

    def broken(_self: object) -> None:
        raise RuntimeError("broken on purpose")

    monkeypatch.setattr(code.Sync, "write_uncommitted", broken)
    probe = box.content / "skills" / "probe-two"
    write_text(probe / "SKILL.md", "---\nname: probe-two\ndescription: For this check.\n---\n")
    try:
        returned = code.main([])
        linked = link_target(box.profile / ".claude" / "skills" / "probe-two")
    finally:
        (probe / "SKILL.md").unlink()
        probe.rmdir()
    out = capfd.readouterr().out
    assert returned == 1, out
    pattern = r"^PROBLEM\s+Listing the uncommitted files stopped partway: RuntimeError: broken"
    assert re.search(pattern, out, re.M), out
    assert re.search(r"^UPDATE\s+1 commit waiting", out, re.M), out
    assert linked is not None, out


@pytest.mark.parametrize("script", ["setup.py", "sync.py", "update.py"])
def test_code_that_cant_load_says_how_to_install_a_fix_by_hand(box: Sandbox, script: str) -> None:
    code = box.tools / "internal" / "shared" / script
    before = code.read_bytes()
    write_text(code, "def (:\n")
    try:
        result = run_python(box, script)
    finally:
        code.write_bytes(before)
    tools = box.tools.as_posix()
    assert result.code == 1, str(result)
    assert result.has_line(rf"^PROBLEM\s+{re.escape(script)} stopped: SyntaxError: "), str(result)
    assert result.has_line(re.escape(f"git -C {tools} pull --ff-only, then py")), str(result)
    assert not result.has_line("Traceback"), str(result)


@pytest.mark.parametrize("script", ["setup.py", "sync.py", "update.py"])
def test_ctrl_c_says_the_script_stopped_instead_of_a_traceback(box: Sandbox, script: str) -> None:
    # Ctrl+C at a console raises KeyboardInterrupt in whatever code is running.
    code = box.tools / "internal" / "shared" / script
    before = code.read_bytes()
    write_text(code, "def main(argv):\n    raise KeyboardInterrupt\n")
    try:
        result = run_python(box, script)
    finally:
        code.write_bytes(before)
    assert result.code == 130, str(result)
    assert result.has_line(rf"^{re.escape(script)} stopped: Ctrl\+C was pressed\.$"), str(result)
    assert not result.has_line("Traceback"), str(result)


# When a sync checks GitHub. Last in this file: these leave updates waiting.


@pytest.fixture
def copies(box: Sandbox) -> Iterator[Callable[[bool | None], None]]:
    """Sets dev-home.json's answer for this test, or removes the file for None, then puts the
    committed file back."""
    path = box.content / "dev-home.json"
    before = path.read_bytes()

    def set_copies(several: bool | None) -> None:
        path.unlink(missing_ok=True)
        if several is not None:
            write_text(path, json.dumps({"multiMachine": several}) + "\n")

    yield set_copies
    path.write_bytes(before)


def age_last_fetch(repo: Path, hours: float) -> None:
    """Moves the time of a repo's last fetch back."""
    then = time.time() - hours * 60 * 60
    os.utime(repo / ".git" / "FETCH_HEAD", (then, then))


def push_from_another_copy(box: Sandbox, line: str) -> None:
    other = other_pc(box)
    append(other / DEMO, line)
    push_from(other, DEMO, "handoff: demo from another copy")


def test_with_one_copy_the_fetch_waits_for_the_check_then_says_to_look_at_the_setting(
    box: Sandbox, copies: Callable[[bool | None], None]
) -> None:
    copies(False)
    sync(box)
    push_from_another_copy(box, "While this copy wasn't looking.")
    result = sync(box, "--fetch", "auto")
    pattern = (
        r"^OK\s+dev-home is up to date: it's the only active copy, and it last checked GitHub "
        r"under a minute ago\.$"
    )
    assert result.code == 0 and result.has_line(pattern), str(result)
    assert not result.has_line(r"^(PULLED|MERGED|SETTING)\s"), str(result)
    age_last_fetch(box.content, 13)
    result = sync(box, "--fetch", "auto")
    assert result.has_line(r"^PULLED\s+1 commit from GitHub\."), str(result)
    pattern = (
        r"^SETTING\s+dev-home brought in 1 commit from another copy, but it's set to one active "
        r"copy\. If another copy is in use, run /dev-home configure\.$"
    )
    assert result.has_line(pattern), str(result)


def test_a_last_fetch_that_failed_counts_as_none(
    box: Sandbox, copies: Callable[[bool | None], None]
) -> None:
    # A fetch that fails empties FETCH_HEAD and still sets its time.
    copies(False)
    write_text(box.content / ".git" / "FETCH_HEAD", "")
    result = sync(box, "--fetch", "auto")
    assert result.has_line(r"^OK\s+dev-home is up to date with GitHub\.$"), str(result)
    assert shared_module(box, "git").last_fetch_age(box.content / ".git") is not None


@pytest.mark.parametrize("several", [True, None], ids=["several copies", "no answer"])
def test_with_several_copies_or_no_answer_it_fetches_every_time(
    box: Sandbox, copies: Callable[[bool | None], None], several: bool | None
) -> None:
    copies(several)
    sync(box)
    push_from_another_copy(box, f"Pushed for {several}.")
    result = sync(box, "--fetch", "auto")
    assert result.has_line(r"^PULLED\s+1 commit from GitHub\."), str(result)
    assert not result.has_line(r"^SETTING\s"), str(result)


def test_when_due_waits_for_the_check_even_with_several_copies(
    box: Sandbox, copies: Callable[[bool | None], None]
) -> None:
    copies(True)
    sync(box)
    result = sync(box, "--fetch", "when-due")
    pattern = (
        r"^OK\s+dev-home wasn't checked with GitHub this time: it last checked under a minute "
        r"ago, and checks every 12 hours\.$"
    )
    assert result.has_line(pattern), str(result)
    set_setting(box, "contentCheckHours", 0)
    try:
        result = sync(box, "--fetch", "when-due")
    finally:
        set_setting(box, "contentCheckHours", None)
    assert result.has_line(r"^OK\s+dev-home is up to date with GitHub\.$"), str(result)


def test_a_skipped_fetch_still_merges_what_came_in_and_pushes_what_waits(
    box: Sandbox, copies: Callable[[bool | None], None]
) -> None:
    copies(False)
    push_from_another_copy(box, "Fetched earlier, not merged yet.")
    git("-C", str(box.content), "fetch", "--quiet")
    write_text(box.content / "notes" / "made-here.md", "made here\n")
    git("-C", str(box.content), "add", "--", "notes/made-here.md")
    git("-C", str(box.content), "commit", "--quiet", "-m", "notes: made here")
    result = sync(box, "--fetch", "auto")
    assert result.has_line(r"^MERGED\s+1 commit from GitHub"), str(result)
    assert result.has_line(r"^SETTING\s+dev-home brought in 1 commit"), str(result)
    assert result.has_line(r"^PUSHED\s+2 commits to GitHub\."), str(result)


def test_with_one_copy_a_failed_check_says_nothing_should_be_missing(
    box: Sandbox, copies: Callable[[bool | None], None]
) -> None:
    copies(False)
    age_last_fetch(box.content, 13)
    url = git("-C", str(box.content), "remote", "get-url", "origin")[0]
    git("-C", str(box.content), "remote", "set-url", "origin", str(box.root / "missing.git"))
    try:
        result = sync(box, "--fetch", "auto")
    finally:
        git("-C", str(box.content), "remote", "set-url", "origin", url)
    pattern = (
        r"^OFFLINE\s+Could not reach GitHub for dev-home's check\. It's set to one active copy, "
        r"so nothing should be missing here\. git: "
    )
    assert result.has_line(pattern), str(result)


def test_a_commit_pushes_without_fetching_first(box: Sandbox) -> None:
    # Fetching from a missing repo would fail with an OFFLINE line, while pushes go to the real
    # one.
    content = str(box.content)
    url = git("-C", content, "remote", "get-url", "origin")[0]
    git("-C", content, "config", "remote.origin.pushurl", url)
    git("-C", content, "remote", "set-url", "origin", str(box.root / "missing.git"))
    append(box.content / DEMO, "Pushed without a fetch.")
    try:
        result = sync(box, "--message", "handoff: demo", DEMO)
    finally:
        git("-C", content, "remote", "set-url", "origin", url)
        git("-C", content, "config", "--unset", "remote.origin.pushurl")
    assert result.code == 0, str(result)
    assert result.has_line(r"^PUSHED\s+1 commit to GitHub\."), str(result)
    assert not result.has_line(r"^OFFLINE\s"), str(result)


def test_setups_commit_brings_in_commits_without_running_setup_or_the_update_check(
    box: Sandbox, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # Setup itself is running, so a sync it starts must not start setup again.
    code = shared_module(box, "sync")
    ran: list[str] = []

    def setup_ran(fresh: bool = False) -> bool:
        ran.append("setup")
        return True

    def update_check_ran(_self: object) -> None:
        ran.append("update check")

    monkeypatch.setattr(code, "run_setup", setup_ran)
    monkeypatch.setattr(code.Sync, "update_tools", update_check_ran)
    push_from_another_copy(box, "Before setup's commit.")
    write_text(box.content / "notes" / "from-setup.md", "committed by setup's sync\n")
    returned = code.commit_for_setup(box.content, "notes/from-setup.md", "notes: from setup")
    out = capsys.readouterr().out
    assert returned == 0, out
    assert re.search(r"^MERGED\s+1 commit from GitHub", out, re.M), out
    assert re.search(r"^PUSHED\s+2 commits to GitHub\.", out, re.M), out
    assert ran == [], ran


def test_the_update_check_waits_its_interval_and_uses_what_it_knows(box: Sandbox) -> None:
    # An update fetched earlier is still waiting: the maintainer's change four.
    set_setting(box, "updateCheckHours", 24)
    try:
        sync(box)
        push_update(box, "Upstream change five.")
        between = sync(box)
        age_last_fetch(box.tools, 25)
        due = sync(box)
        push_update(box, "Upstream change six.")
        by_hand = run_python(box, "update.py", answer="n")
    finally:
        set_setting(box, "updateCheckHours", 0)
    assert between.has_line(r"^UPDATE\s+1 commit waiting"), str(between)
    assert due.has_line(r"^UPDATE\s+2 commits waiting"), str(due)
    # update.py run by hand always checks GitHub.
    assert by_hand.has_line(r"handoff: Upstream change six\."), str(by_hand)
