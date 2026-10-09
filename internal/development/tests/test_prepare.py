"""prepare.py, run as the skills run it in Claude Code, from a sandbox's generated copy.

Its sync is real: the sandbox's copy of this repo is a git clone with a remote, as a person's is,
so the sync's update check and setup run too. test_sync.py covers the sync itself.
"""

import os
import re
import shutil
from collections.abc import Iterator
from pathlib import Path

import pytest

from helpers import (
    Sandbox,
    git,
    new_repo,
    run_command,
    run_python,
    sandbox_for,
    skill_command,
    write_text,
)

pytestmark = pytest.mark.xdist_group("prepare")

FACT_KEYS = [
    "service",
    "name",
    "handoff",
    "draft",
    "link",
    "project",
    "environment",
    "checked",
    "newer",
    "behind",
    "offerSecurityBugs",
]


@pytest.fixture(scope="module")
def box(request: pytest.FixtureRequest) -> Iterator[Sandbox]:
    yield from sandbox_for(request, "prepare", tools_repo=True)


@pytest.fixture(scope="module")
def project(box: Sandbox) -> Path:
    return new_repo(box, "project", origin="https://github.com/you/tool.git")


def index_of(lines: list[str], pattern: str) -> int:
    return next((i for i, line in enumerate(lines) if re.search(pattern, line)), -1)


def test_syncs_first_then_prints_the_facts_in_order_and_exits_0(
    box: Sandbox, project: Path
) -> None:
    result = run_command(box, skill_command(box, "handoff", "prepare.py"), cwd=project)
    synced = index_of(result.lines, r"^OK\s+dev-home is up to date")
    assert result.code == 0, str(result)
    assert 0 <= synced < index_of(result.lines, r"^service: "), str(result)
    assert result.keys == FACT_KEYS, str(result)


def test_passes_fetch_to_the_sync_and_the_rest_to_facts(box: Sandbox, project: Path) -> None:
    # The handoff skill's --fetch auto fetches every time here, since the sandbox's dev-home is
    # set to several copies.
    command = skill_command(box, "handoff", "prepare.py")
    assert " --fetch auto " in command, command
    run_command(box, command, cwd=project)
    when_due = command.replace(" --fetch auto ", " --fetch when-due ")
    result = run_command(box, when_due, cwd=project)
    assert result.code == 0, str(result)
    assert result.has_line(r"^OK\s+dev-home wasn't checked with GitHub this time"), str(result)
    assert result.keys == FACT_KEYS, str(result)
    result = run_command(box, command.replace(" --fetch auto ", " --fetch sometimes "), cwd=project)
    assert result.has_line(r"^PROBLEM\s+--fetch needs one of these after it"), str(result)
    assert result.keys == FACT_KEYS, str(result)


@pytest.mark.parametrize(
    ("fetch", "said"),
    [
        # Plain /knowledge, right after another sync's fetch.
        ("--fetch when-due", r"^OK\s+dev-home wasn't checked with GitHub this time"),
        # Before adding a note, with several copies.
        ("--fetch auto", r"^OK\s+dev-home is up to date with GitHub\."),
    ],
)
def test_the_knowledge_skills_two_commands_only_sync(
    box: Sandbox, project: Path, fetch: str, said: str
) -> None:
    run_command(box, skill_command(box, "handoff", "prepare.py"), cwd=project)
    command = skill_command(box, "knowledge", "prepare.py", containing=fetch)
    result = run_command(box, command, cwd=project)
    assert result.code == 0, str(result)
    assert result.has_line(said), str(result)
    assert result.keys == [], str(result)


def test_the_dev_home_skills_sync_fetches_every_time(box: Sandbox, project: Path) -> None:
    # Even when dev-home is set to one copy, and a fetch has just been made.
    settings = box.content / "dev-home.json"
    before = settings.read_bytes()
    write_text(settings, '{\n  "multiMachine": false\n}\n')
    try:
        run_command(box, skill_command(box, "handoff", "prepare.py"), cwd=project)
        result = run_command(box, skill_command(box, "dev-home", "prepare.py"), cwd=project)
    finally:
        settings.write_bytes(before)
    assert result.code == 0, str(result)
    assert result.has_line(r"^OK\s+dev-home is up to date with GitHub\."), str(result)
    assert result.keys == [], str(result)


def test_runs_through_the_python_link_as_written(box: Sandbox, project: Path) -> None:
    command = skill_command(box, "handoff", "prepare.py")
    result = run_command(box, command, cwd=project, through_link=True)
    assert result.code == 0, str(result)
    assert result.keys == FACT_KEYS, str(result)


def test_passes_on_an_accented_letter_in_a_fact_as_it_is(box: Sandbox) -> None:
    repo = new_repo(box, "accented", origin="https://dev.azure.com/Org/Proj/_git/R%C3%A9po")
    result = run_command(box, skill_command(box, "handoff", "prepare.py"), cwd=repo)
    assert result.facts["handoff"] == "handoffs/azure-devops/org/proj/répo/HANDOFF.md", str(result)


def test_when_facts_stops_says_why_prints_no_fact_and_exits_0(box: Sandbox, project: Path) -> None:
    command = skill_command(box, "handoff", "prepare.py") + " weather"
    result = run_command(box, command, cwd=project)
    assert result.code == 0, str(result)
    assert result.has_line(r"^PROBLEM\s+facts\.py stopped.*No such topic: weather"), str(result)
    assert result.keys == [], str(result)


def test_when_the_sync_reports_a_problem_still_prints_the_facts(
    box: Sandbox, project: Path
) -> None:
    # The sync stops and returns 1 without local-settings.json, before it could run setup.
    settings = box.tools / "local-settings.json"
    hidden = settings.with_name("local-settings.json.off")
    settings.rename(hidden)
    try:
        result = run_command(box, skill_command(box, "handoff", "prepare.py"), cwd=project)
    finally:
        hidden.rename(settings)
    assert result.code == 0, str(result)
    assert result.has_line(r"^PROBLEM\s.*not set up on this PC"), str(result)
    assert result.keys == FACT_KEYS, str(result)


def test_needs_no_powershell(box: Sandbox, project: Path) -> None:
    # Everything runs in Python, setup included, so nothing is missing without pwsh in PATH.
    folders = os.environ["PATH"].split(os.pathsep)
    path = os.pathsep.join(f for f in folders if not shutil.which("pwsh", path=f))
    command = skill_command(box, "handoff", "prepare.py")
    result = run_command(box, command, cwd=project, env={"PATH": path})
    assert result.code == 0, str(result)
    assert result.has_line(r"^OK\s+dev-home is up to date"), str(result)
    assert not result.has_line(r"^PROBLEM\s"), str(result)
    assert result.keys == FACT_KEYS, str(result)


def test_when_the_sync_cant_load_says_so_and_still_prints_the_facts(
    box: Sandbox, project: Path
) -> None:
    sync = box.tools / "internal" / "shared" / "sync.py"
    before = sync.read_bytes()
    write_text(sync, "this is not Python\n")
    try:
        result = run_command(box, skill_command(box, "handoff", "prepare.py"), cwd=project)
    finally:
        sync.write_bytes(before)
    assert result.code == 0, str(result)
    assert result.has_line(r"^PROBLEM\s+The sync stopped, so dev-home may be behind"), str(result)
    tools = box.tools.as_posix()
    assert result.has_line(re.escape(f"installs it by hand: git -C {tools} pull --ff-only")), str(
        result
    )
    assert result.keys == FACT_KEYS, str(result)


def test_runs_the_facts_that_the_syncs_setup_has_just_written(box: Sandbox, project: Path) -> None:
    template = box.tools / "templates" / "shared-skill-scripts" / "facts.py"
    text = template.read_text(encoding="utf-8")
    write_text(template, text.replace('f"environment: {', 'f"environment: (new copy) {'))
    try:
        command = skill_command(box, "handoff", "prepare.py")
        result = run_command(box, command, cwd=project)
    finally:
        write_text(template, text)
        run_python(box, "setup.py", "--quiet")
    assert result.code == 0, str(result)
    assert result.facts["environment"].startswith("(new copy) "), str(result)


def test_when_the_syncs_setup_changes_the_skill_says_reload_and_no_facts(
    box: Sandbox, project: Path
) -> None:
    command = skill_command(box, "handoff", "prepare.py")
    skill = box.tools / "templates" / "skills" / "handoff" / "SKILL.md"
    text = skill.read_text(encoding="utf-8")
    write_text(skill, text + "\nA line added to the skill.\n")
    try:
        result = run_command(box, command, cwd=project)
        new_command = skill_command(box, "handoff", "prepare.py")
    finally:
        write_text(skill, text)
        run_python(box, "setup.py", "--quiet")
    assert result.code == 0, str(result)
    assert result.has_line(r"^RELOAD\s+The handoff skill has changed since this session"), str(
        result
    )
    assert result.keys == [], str(result)
    assert new_command != command, "the skill on disk has a new stamp"
    assert run_command(box, command, cwd=project).keys == FACT_KEYS, "and the old one is back"


def test_commits_nothing(box: Sandbox, project: Path) -> None:
    before = git("-C", str(box.content), "rev-parse", "HEAD")
    write_text(box.content / "knowledge" / "uncommitted.md", "# Not committed\n")
    try:
        run_command(box, skill_command(box, "handoff", "prepare.py"), cwd=project)
        assert git("-C", str(box.content), "rev-parse", "HEAD") == before
        status = git("-C", str(box.content), "status", "--porcelain")
        assert status == ["?? knowledge/uncommitted.md"], status
    finally:
        (box.content / "knowledge" / "uncommitted.md").unlink()
