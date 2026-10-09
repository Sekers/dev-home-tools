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
    """gh's GraphQL requests, answering each with the next answer a test gives, the last one
    again once they run out, and recording each query."""

    def __init__(self, module: ModuleType, code: int, out: object, err: str = "") -> None:
        self.module = module
        self.results: list[Any] = []
        self.queries: list[str] = []
        self.then(code, out, err)

    def then(self, code: int, out: object, err: str = "") -> "FakeGh":
        """Adds the answer to the next request."""
        text = out if isinstance(out, str) else json.dumps(out)
        self.results.append(self.module.GhResult(code, text, err))
        return self

    def __call__(self, gh: str, text: str) -> Any:
        self.queries.append(text)
        return self.results[min(len(self.queries), len(self.results)) - 1]


def closed(reason: str, original: object = None) -> dict[str, object]:
    """GitHub's answer for an issue closed for a reason, such as NOT_PLANNED."""
    return {"issue": {"state": "CLOSED", "stateReason": reason, "duplicateOf": original}}


def close_details(closer: str, *comments: tuple[str | None, str]) -> dict[str, object]:
    """GitHub's answer to the second request for one issue: who closed it on 2026-10-01, and its
    comments, each an author (None for an account that's gone) and a body."""
    return {
        "issue": {
            "timelineItems": {
                "nodes": [{"createdAt": "2026-10-01T10:00:00Z", "actor": {"login": closer}}]
            },
            "comments": {
                "nodes": [
                    {
                        "createdAt": f"2026-09-{20 + n}T08:00:00Z",
                        "author": None if author is None else {"login": author},
                        "body": body,
                    }
                    for n, (author, body) in enumerate(comments)
                ]
            },
        }
    }


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
            "i0": {"issue": {"state": "OPEN", "stateReason": None, "duplicateOf": None}},
            "i1": closed("COMPLETED"),
            "i2": closed("NOT_PLANNED"),
            "i3": None,
            "i4": closed("DUPLICATE"),
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
    details = {
        "data": {
            "viewer": {"login": "you-on-github"},
            "c0": close_details(
                "octocat", ("you-on-github", "Still\n\nseeing this."), (None, "x" * 600)
            ),
        }
    }
    # gh exits 1 when any part of the query fails, and still prints what GitHub answered.
    gh = FakeGh(module, 1, answer, "gh: Could not resolve to a Repository").then(0, details)
    lines = run_here(box, project, monkeypatch, capsys, gh, module)
    assert lines == [
        "OPEN      https://github.com/you/tool/issues/1",
        "CLOSED    https://github.com/you/tool/issues/2 (completed)",
        "CLOSED    https://github.com/other/lib/issues/3 (not planned, by octocat on 2026-10-01)",
        "COMMENT   https://github.com/other/lib/issues/3 you on 2026-09-20: Still seeing this.",
        "COMMENT   https://github.com/other/lib/issues/3 an account that's gone on 2026-09-21: "
        + "x" * 500
        + "... (cut)",
        "UNCHECKED https://github.com/gone/repo/issues/4 (GitHub didn't return it: Could not "
        "resolve to a Repository with the name 'gone/repo'.)",
        "CLOSED    https://github.com/you/tool/issues/5 (duplicate)",
        "CLOSED    https://github.com/x/y/issues/6",
    ], lines
    assert len(gh.queries) == 2, gh.queries
    query = gh.queries[0]
    assert query.startswith('query { i0: repository(owner: "you", name: "tool") '), query
    assert (
        "{ issue(number: 1) { state stateReason duplicateOf { url title state stateReason } } }"
        in query
    ), query
    assert "i6:" not in query and "mutation" not in query, query
    # The second asks only about the issue closed as not planned.
    second = gh.queries[1]
    assert second.startswith(
        'query { viewer { login } c0: repository(owner: "other", name: "lib") { issue(number: 3) '
    ), second
    assert "comments(last: 3)" in second and "c1:" not in second, second
    assert "mutation" not in second, second


def test_a_duplicate_names_the_issue_it_duplicates_its_state_and_title(
    box: Sandbox,
    project: Path,
    handoff: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    write_text(
        handoff, "https://github.com/you/tool/issues/9\nhttps://github.com/you/tool/issues/8\n"
    )
    module = load(box)
    url = "https://github.com/you/tool/issues/"
    answer = {
        "data": {
            "i0": closed(
                "DUPLICATE", {"url": url + "4", "title": "Imports  fail", "state": "OPEN"}
            ),
            "i1": closed(
                "DUPLICATE",
                {"url": url + "2", "title": "Old", "state": "CLOSED", "stateReason": "COMPLETED"},
            ),
        }
    }
    gh = FakeGh(module, 0, answer)
    assert run_here(box, project, monkeypatch, capsys, gh, module) == [
        f"CLOSED    {url}9 (duplicate of {url}4, which is open: Imports fail)",
        f"CLOSED    {url}8 (duplicate of {url}2, which is closed as completed: Old)",
    ]
    assert len(gh.queries) == 1, "no second request without a not-planned close"


@pytest.mark.parametrize(
    ("second", "says"),
    [
        (
            (0, {"data": {"viewer": {"login": "me"}, "c0": close_details("me")}}),
            ["(not planned, by you on 2026-10-01)", "COMMENT   {url} (no comments)"],
        ),
        (
            (4, "", "To get started with GitHub CLI, please run:  gh auth login"),
            [
                "(not planned; who closed it, and why, couldn't be read: gh isn't signed in to "
                "GitHub: the user runs gh auth login)"
            ],
        ),
        (
            (1, {"data": {"viewer": {"login": "me"}, "c0": None}}),
            ["(not planned; who closed it, and why, couldn't be read: GitHub didn't return it)"],
        ),
    ],
    ids=["closed by the signed-in account, no comments", "signed out since", "not returned"],
)
def test_a_not_planned_close_says_who_closed_it_or_why_that_couldnt_be_read(
    box: Sandbox,
    project: Path,
    handoff: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    second: tuple[Any, ...],
    says: list[str],
) -> None:
    url = "https://github.com/you/tool/issues/3"
    write_text(handoff, f"- Waiting on {url}.\n")
    module = load(box)
    gh = FakeGh(module, 0, {"data": {"i0": closed("NOT_PLANNED")}}).then(*second)
    lines = run_here(box, project, monkeypatch, capsys, gh, module)
    assert lines[0] == f"CLOSED    {url} {says[0]}", lines
    assert lines[1:] == [line.format(url=url) for line in says[1:]], lines


def test_leaves_out_links_after_see_also_in_their_item(box: Sandbox) -> None:
    module = load(box)
    url = "https://github.com/you/tool/issues/"
    text = (
        f"- GitHub issue [#1]({url}1): a bug. See also: [#2]({url}2)\n"
        f"  and {url}3, on the item's next line.\n"
        f"- Waiting on {url}4. See also, without a colon, {url}5\n"
        f"- The next item: {url}2\n"
        "\n"
        f"A new paragraph: {url}3\n"
        f"SEE ALSO: {url}6\n"
        f"## A heading, which ends the item: {url}7\n"
    )
    found = [issue.url for issue in module.issue_links(text)]
    assert found == [url + n for n in ("1", "4", "5", "2", "3", "7")], found


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
