"""issue_status.py, the handoff skill's check of the GitHub issues a handoff links to.

The tests never reach GitHub, so most run the script's code in this process, from a sandbox's
generated copy, with gh faked. One runs the skill's command as a process, with no gh in PATH.
"""

import importlib.util
import json
import os
import shutil
import subprocess
from collections.abc import Iterator
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

from helpers import Sandbox, new_repo, run_command, sandbox_for, skill_command, write_text

pytestmark = pytest.mark.xdist_group("issue-status")

HANDOFF = "handoffs/github/you/tool/HANDOFF.md"
NO_LINKS = "OK        The handoff links no GitHub issues."


@pytest.fixture(scope="module")
def box(request: pytest.FixtureRequest) -> Iterator[Sandbox]:
    yield from sandbox_for(request, "issue-status")


@pytest.fixture(scope="module")
def project(box: Sandbox) -> Path:
    return new_repo(box, "project", origin="https://github.com/you/tool.git")


@pytest.fixture
def handoff(box: Sandbox) -> Iterator[Path]:
    """This project's handoff in the sandbox's dev-home, removed after the test."""
    path = box.content / HANDOFF
    yield path
    path.unlink(missing_ok=True)


def load(box: Sandbox) -> ModuleType:
    """The sandbox's generated issue_status.py, whose paths setup has filled in."""
    path = box.generated / "skills" / "handoff" / "issue_status.py"
    spec = importlib.util.spec_from_file_location("issue_status_" + box.root.name[-8:], path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeGh:
    """gh's GraphQL request, answering with what a test gives, and recording each query."""

    def __init__(self, module: ModuleType, code: int, out: object, err: str = "") -> None:
        self.result = module.GhResult(code, out if isinstance(out, str) else json.dumps(out), err)
        self.queries: list[str] = []

    def __call__(self, gh: str, text: str) -> Any:
        self.queries.append(text)
        return self.result


def run_here(
    box: Sandbox,
    project: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    gh: FakeGh | None,
    module: ModuleType | None = None,
) -> list[str]:
    """Runs the script's main in the project's folder, with gh faked, and returns its lines."""
    module = module or load(box)
    monkeypatch.chdir(project)
    monkeypatch.setattr(module, "find_gh", lambda facts: "gh")
    if gh is not None:
        monkeypatch.setattr(module, "run_gh", gh)
    assert module.main() == 0
    return capsys.readouterr().out.splitlines()


def test_says_whether_each_link_is_open_or_closed_and_why_once_each(
    box: Sandbox,
    project: Path,
    handoff: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    write_text(
        handoff,
        "# tool handoff\n\n"
        "- GitHub issue [#1](https://github.com/you/tool/issues/1): open.\n"
        "- GitHub issue [#2](https://github.com/you/tool/issues/2): done.\n"
        "- Waiting on [other/lib#3](https://github.com/other/lib/issues/3).\n"
        "- The same as the first, in other case: https://github.com/You/Tool/issues/1.\n"
        "- Gone: https://github.com/gone/repo/issues/4\n"
        "- https://github.com/you/tool/issues/5 and https://github.com/x/y/issues/6\n"
        "- Not an issue: https://github.com/you/tool/pull/7\n",
    )
    module = load(box)
    answer = {
        "data": {
            "i0": {"issue": {"state": "OPEN", "stateReason": None}},
            "i1": {"issue": {"state": "CLOSED", "stateReason": "COMPLETED"}},
            "i2": {"issue": {"state": "CLOSED", "stateReason": "NOT_PLANNED"}},
            "i3": None,
            "i4": {"issue": {"state": "CLOSED", "stateReason": "DUPLICATE"}},
            "i5": {"issue": {"state": "CLOSED", "stateReason": None}},
        },
        "errors": [
            {
                "type": "NOT_FOUND",
                "path": ["i3"],
                "message": "Could not resolve to a Repository with the name 'gone/repo'.",
            }
        ],
    }
    # gh exits 1 when any part of the query fails, and still prints what GitHub answered.
    gh = FakeGh(module, 1, answer, "gh: Could not resolve to a Repository")
    lines = run_here(box, project, monkeypatch, capsys, gh, module)
    assert lines == [
        "OPEN      https://github.com/you/tool/issues/1",
        "CLOSED    https://github.com/you/tool/issues/2 (completed)",
        "CLOSED    https://github.com/other/lib/issues/3 (not planned)",
        "UNCHECKED https://github.com/gone/repo/issues/4 (GitHub didn't return it: Could not "
        "resolve to a Repository with the name 'gone/repo'.)",
        "CLOSED    https://github.com/you/tool/issues/5 (duplicate)",
        "CLOSED    https://github.com/x/y/issues/6",
    ], lines
    assert len(gh.queries) == 1, gh.queries
    query = gh.queries[0]
    assert query.startswith('query { i0: repository(owner: "you", name: "tool") '), query
    assert "{ issue(number: 1) { state stateReason } }" in query, query
    assert "i6:" not in query and "mutation" not in query, query


@pytest.mark.parametrize("text", ["# tool handoff\n\nNo issues here.\n", None])
def test_with_no_issue_links_says_so_and_asks_github_nothing(
    box: Sandbox,
    project: Path,
    handoff: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    text: str | None,
) -> None:
    if text is not None:
        write_text(handoff, text)
    module = load(box)
    gh = FakeGh(module, 0, {"data": {}})
    assert run_here(box, project, monkeypatch, capsys, gh, module) == [NO_LINKS]
    assert gh.queries == []


@pytest.mark.parametrize(
    ("code", "out", "err", "why"),
    [
        (4, "", "To get started with GitHub CLI, please run:  gh auth login", "gh auth login"),
        (
            1,
            '{"message": "Bad credentials", "status": "401"}',
            "gh: Bad credentials (HTTP 401)",
            "gh failed: gh: Bad credentials (HTTP 401)",
        ),
        (1, "", "error connecting to api.github.com", "gh failed: error connecting to api"),
    ],
    ids=["signed out", "bad credentials", "offline"],
)
def test_when_gh_gives_no_answer_says_why_for_each_link(
    box: Sandbox,
    project: Path,
    handoff: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    code: int,
    out: str,
    err: str,
    why: str,
) -> None:
    write_text(
        handoff, "https://github.com/you/tool/issues/1\nhttps://github.com/you/tool/issues/2\n"
    )
    module = load(box)
    lines = run_here(box, project, monkeypatch, capsys, FakeGh(module, code, out, err), module)
    assert len(lines) == 2, lines
    assert all(line.startswith("UNCHECKED https://github.com/you/tool/issues/") for line in lines)
    assert all(why in line for line in lines), lines


def test_asks_gh_one_read_only_query_and_never_lets_it_prompt(
    box: Sandbox, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = load(box)
    seen: list[tuple[list[str], dict[str, str]]] = []

    def fake_run(argv: list[str], **options: Any) -> subprocess.CompletedProcess[str]:
        seen.append((argv, options["env"]))
        return subprocess.CompletedProcess(argv, 0, '{"data": {}}', "")

    monkeypatch.setattr(module.subprocess, "run", fake_run)
    issues = module.issue_links("https://github.com/you/tool/issues/1")
    result = module.run_gh("gh", module.query(issues))
    assert result.code == 0
    argv, env = seen[0]
    assert argv[:4] == ["gh", "api", "graphql", "-f"], argv
    assert argv[4].startswith("query=query { "), argv
    assert env["GH_PROMPT_DISABLED"] == "1"


def test_when_it_stops_says_so_and_exits_0(
    box: Sandbox,
    project: Path,
    handoff: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    write_text(handoff, "https://github.com/you/tool/issues/1\n")
    module = load(box)

    def broken(text: str) -> list[object]:
        raise RuntimeError("a bug")

    monkeypatch.setattr(module, "issue_links", broken)
    lines = run_here(box, project, monkeypatch, capsys, None, module)
    assert lines == [
        "PROBLEM   issue_status.py stopped, so no issue was checked: RuntimeError: a bug"
    ], lines


def test_the_skills_command_without_gh_in_path_says_so_and_exits_0(
    box: Sandbox, project: Path, handoff: Path
) -> None:
    write_text(handoff, "- GitHub issue [#1](https://github.com/you/tool/issues/1): a bug.\n")
    folders = os.environ["PATH"].split(os.pathsep)
    path = os.pathsep.join(f for f in folders if not shutil.which("gh", path=f))
    assert shutil.which("git", path=path), "the test needs git without gh"
    command = skill_command(box, "handoff", "issue_status.py")
    result = run_command(box, command, cwd=project, env={"PATH": path})
    assert result.code == 0, str(result)
    assert result.lines == [
        "UNCHECKED https://github.com/you/tool/issues/1 (gh, the GitHub CLI, isn't installed, "
        "or isn't in PATH)"
    ], str(result)
