"""facts.py, run as the handoff skill runs it in Codex, from a sandbox's generated copy."""

import os
import shutil
import sys
from collections.abc import Iterator
from pathlib import Path

import pytest

from helpers import Run, Sandbox, git, new_repo, run_command, sandbox_for, skill_command, write_text

pytestmark = pytest.mark.xdist_group("facts")


@pytest.fixture(scope="module")
def box(request: pytest.FixtureRequest) -> Iterator[Sandbox]:
    yield from sandbox_for(request, "facts")


def facts(
    box: Sandbox,
    folder: Path,
    *topics: str,
    env: dict[str, str | None] | None = None,
) -> Run:
    """Runs facts.py in a folder with the handoff skill's own command, for the topics given in
    place of the skill's, or the handoff topic when none are given."""
    words = skill_command(box, "handoff", "facts.py").split(" ")
    options = words[: words.index("--stamp") + 2]
    return run_command(box, " ".join([*options, *(topics or ("handoff",))]), cwd=folder, env=env)


def first_commit(repo: Path) -> str:
    """The start of a repo's first commit on the main line, worked out here without facts.py."""
    return git("-C", str(repo), "rev-list", "--first-parent", "--max-parents=0", "HEAD")[0][:7]


def short_head(repo: Path) -> str:
    return git("-C", str(repo), "rev-parse", "--short=7", "HEAD")[0]


# Each address, and the folder under handoffs/ it should get. {id} stands for the start of the
# sample repo's first commit.
ADDRESSES = {
    "https://github.com/You/Tool.git": "github/you/tool",
    "git@github.com:You/Tool.git": "github/you/tool",
    "ssh://git@github.com/You/Tool": "github/you/tool",
    "https://user:secret@github.com:443/you/tool/": "github/you/tool",
    "https://gitlab.com/Team/Sub/App.git": "gitlab/team/sub/app",
    "git@gitlab.com:team/sub/app.git": "gitlab/team/sub/app",
    "https://someone@bitbucket.org/Space/Repo.git": "bitbucket/space/repo",
    "git@bitbucket.org:space/repo.git": "bitbucket/space/repo",
    "https://Org@dev.azure.com/Org/My%20Project/_git/Repo": "azure-devops/org/my project/repo",
    "git@ssh.dev.azure.com:v3/Org/My%20Project/Repo": "azure-devops/org/my project/repo",
    "https://dev.azure.com/Org/_git/Repo": "azure-devops/org/repo/repo",
    "https://git.example.com/team/app.git": "other/sample repo-{id}",
    "git@git.example.com:team/app.git": "other/sample repo-{id}",
    "https://github.com/just-an-owner": "other/sample repo-{id}",
    "https://github.com/you/%2E%2E": "other/sample repo-{id}",
    "https://gitlab.com/team/../../outside": "other/sample repo-{id}",
    "https://github.com/you/to*ol": "other/sample repo-{id}",
    "C:/repos/tool": "local/sample repo-{id}",
    "C:\\repos\\tool": "local/sample repo-{id}",
    "file:///C:/repos/tool": "local/sample repo-{id}",
    "../tool": "local/sample repo-{id}",
}


@pytest.fixture(scope="module")
def sample(box: Sandbox) -> Path:
    return new_repo(box, "Sample Repo", origin="https://github.com/You/Tool.git")


@pytest.mark.parametrize(("address", "folder"), ADDRESSES.items())
def test_files_each_address_under_its_folder(
    box: Sandbox, sample: Path, address: str, folder: str
) -> None:
    git("-C", str(sample), "remote", "set-url", "origin", address)
    try:
        result = facts(box, sample)
    finally:
        git("-C", str(sample), "remote", "set-url", "origin", "https://github.com/You/Tool.git")
    expected = f"handoffs/{folder.replace('{id}', first_commit(sample))}/HANDOFF.md"
    assert result.code == 0, str(result)
    assert result.facts["handoff"] == expected, str(result)


def test_prints_the_handoff_topics_six_lines_in_order(box: Sandbox, sample: Path) -> None:
    result = facts(box, sample)
    assert result.keys == ["service", "name", "handoff", "draft", "link", "project"], str(result)
    assert len(result.lines) == 6, str(result)
    assert result.facts["service"] == "github"
    assert result.facts["name"] == "you/tool"
    assert result.facts["draft"] == ".drafts/github/you/tool/issue.md"
    # The sandbox keeps dev-home beside the sample repo.
    assert result.facts["link"] == "../dev-home/handoffs/github/you/tool/HANDOFF.md"
    assert result.facts["project"] == "."


def test_the_environment_topic_prints_this_computers_name(box: Sandbox, sample: Path) -> None:
    result = facts(box, sample, "environment")
    if sys.platform == "win32":
        name = os.environ["COMPUTERNAME"]
    else:
        name = os.uname().nodename.split(".")[0]
    assert result.code == 0, str(result)
    assert result.lines == [f"environment: {name}"], str(result)


def test_two_topics_print_in_the_order_asked(box: Sandbox, sample: Path) -> None:
    result = facts(box, sample, "environment", "handoff")
    assert result.code == 0, str(result)
    assert result.keys == ["environment", "service", "name", "handoff", "draft", "link", "project"]


def test_with_no_topic_stops_and_names_the_topics(box: Sandbox, sample: Path) -> None:
    words = skill_command(box, "handoff", "facts.py").split(" ")
    result = run_command(box, " ".join(words[: words.index("--stamp") + 2]), cwd=sample)
    assert result.code == 1, str(result)
    assert result.keys == [], str(result)
    assert result.has_line("at least one topic: handoff, environment, newer-commits"), str(result)


def test_an_unknown_topic_stops_it_before_any_fact(box: Sandbox, sample: Path) -> None:
    result = facts(box, sample, "environment", "weather")
    assert result.code == 1, str(result)
    assert result.keys == [], str(result)
    assert result.has_line("No such topic: weather"), str(result)


def test_writes_what_a_link_cant_hold_encoded_and_the_path_as_utf8(box: Sandbox) -> None:
    # A repo named with an accent, a space, #, %, and parentheses.
    repo = new_repo(
        box,
        "Encoded",
        origin="https://dev.azure.com/Org/My%20Project/_git/R%C3%A9po%20%231%20(100%25)",
    )
    result = facts(box, repo)
    assert result.facts["link"] == (
        "../dev-home/handoffs/azure-devops/org/my%20project/r%C3%A9po%20%231%20%28100%25%29/HANDOFF.md"
    ), str(result)
    assert result.facts["handoff"] == (
        "handoffs/azure-devops/org/my project/r\u00e9po #1 (100%)/HANDOFF.md"
    ), str(result)


def test_another_host_goes_under_other_by_folder_and_first_commit(box: Sandbox) -> None:
    repo = new_repo(box, "Other Host", origin="https://git.example.com/team/app.git")
    result = facts(box, repo)
    name = f"other host-{first_commit(repo)}"
    assert result.facts["service"] == "other", str(result)
    assert result.facts["name"] == name, str(result)
    assert result.facts["draft"] == f".drafts/other/{name}/issue.md", str(result)


def test_no_origin_goes_under_local_and_a_space_becomes_percent_20(box: Sandbox) -> None:
    repo = new_repo(box, "No Origin")
    name = f"no origin-{first_commit(repo)}"
    result = facts(box, repo)
    assert result.facts["service"] == "local", str(result)
    assert result.facts["handoff"] == f"handoffs/local/{name}/HANDOFF.md", str(result)
    assert result.facts["link"] == (
        f"../dev-home/handoffs/local/{name.replace(' ', '%20')}/HANDOFF.md"
    ), str(result)


def test_in_a_subfolder_the_links_lead_up(box: Sandbox) -> None:
    repo = new_repo(box, "With Sub")
    (repo / "docs").mkdir()
    result = facts(box, repo / "docs")
    name = f"with%20sub-{first_commit(repo)}"
    assert result.facts["link"] == f"../../dev-home/handoffs/local/{name}/HANDOFF.md", str(result)
    assert result.facts["project"] == "..", str(result)


def test_in_claude_codes_cli_the_links_are_file_urls(box: Sandbox) -> None:
    # Claude Code's CLI shows replies in a terminal, which opens file:/// URLs but not relative
    # paths. Git may spell the project folder's drive letter in another case.
    repo = new_repo(box, "Cli Links")
    (repo / "docs").mkdir(exist_ok=True)
    result = facts(box, repo / "docs", env={"CLAUDE_CODE_ENTRYPOINT": "cli"})
    name = f"cli%20links-{first_commit(repo)}"
    handoff = f"file:///{box.content.as_posix()}/handoffs/local/{name}/HANDOFF.md"
    project = f"file:///{repo.as_posix().replace(' ', '%20')}"
    assert result.facts["link"] == handoff, str(result)
    assert result.facts["project"].lower() == project.lower(), str(result)


def test_anywhere_else_claude_code_runs_the_links_stay_relative(box: Sandbox) -> None:
    repo = new_repo(box, "Vscode Links")
    result = facts(box, repo, env={"CLAUDE_CODE_ENTRYPOINT": "claude-vscode"})
    name = f"vscode%20links-{first_commit(repo)}"
    assert result.facts["link"] == f"../dev-home/handoffs/local/{name}/HANDOFF.md", str(result)
    assert result.facts["project"] == ".", str(result)


def test_merged_in_unrelated_history_keeps_the_main_lines_first_commit(box: Sandbox) -> None:
    repo = new_repo(box, "Merged")
    first = first_commit(repo)
    git("-C", str(repo), "checkout", "--quiet", "--orphan", "other-history")
    git("-C", str(repo), "commit", "--quiet", "--allow-empty", "-m", "test: other history")
    git("-C", str(repo), "checkout", "--quiet", "main")
    git(
        "-C",
        str(repo),
        "merge",
        "--quiet",
        "--no-ff",
        "--allow-unrelated-histories",
        "-m",
        "test: merge",
        "other-history",
    )
    assert len(git("-C", str(repo), "rev-list", "--max-parents=0", "HEAD")) == 2
    result = facts(box, repo)
    assert result.facts["handoff"] == f"handoffs/local/merged-{first}/HANDOFF.md", str(result)


def test_a_repo_with_no_commits_goes_by_its_folder_name_alone(box: Sandbox) -> None:
    repo = new_repo(box, "Empty Repo", commits=())
    result = facts(box, repo)
    assert result.facts["handoff"] == "handoffs/local/empty repo/HANDOFF.md", str(result)


def test_a_shallow_clone_goes_by_its_folder_name_alone(box: Sandbox) -> None:
    # A shallow clone's oldest commit is only where the download stopped, not the first one.
    source = new_repo(box, "shallow-source", commits=("one", "two"))
    shallow = box.root / "Shallow Clone"
    git("clone", "--quiet", "--depth", "1", f"file:///{source.as_posix()}", str(shallow))
    result = facts(box, shallow)
    assert result.facts["handoff"] == "handoffs/local/shallow clone/HANDOFF.md", str(result)


def test_a_folder_outside_git_goes_under_local_by_its_name(box: Sandbox) -> None:
    plain = box.root / "Plain Folder"
    plain.mkdir()
    result = facts(box, plain)
    assert result.facts["handoff"] == "handoffs/local/plain folder/HANDOFF.md", str(result)
    assert result.facts["project"] == ".", str(result)


def test_a_worktree_uses_its_main_checkouts_name_and_origin(box: Sandbox) -> None:
    main = new_repo(box, "Main Checkout")
    worktree = box.root / "worktree"
    git("-C", str(main), "worktree", "add", "--quiet", str(worktree))
    result = facts(box, worktree)
    expected = f"handoffs/local/main checkout-{first_commit(main)}/HANDOFF.md"
    assert result.facts["handoff"] == expected, str(result)
    git("-C", str(main), "remote", "add", "origin", "git@github.com:you/tool.git")
    result = facts(box, worktree)
    assert result.facts["handoff"] == "handoffs/github/you/tool/HANDOFF.md", str(result)


def test_in_a_repo_git_cant_read_stops_instead_of_guessing(box: Sandbox) -> None:
    # A guessed path would file the handoff in the wrong place.
    broken = new_repo(box, "Broken Repo")
    with (broken / ".git" / "config").open("a", encoding="utf-8") as config:
        config.write("[broken\n")
    result = facts(box, broken)
    assert result.code == 1, str(result)
    assert "handoff" not in result.facts, str(result)
    assert result.has_line("bad config"), str(result)
    result = facts(box, broken, "environment", "handoff")
    assert result.code == 1, str(result)
    assert result.keys == [], "when one topic fails, no fact from the others either"


def test_without_git_stops_instead_of_guessing(box: Sandbox, sample: Path) -> None:
    folders = os.environ["PATH"].split(os.pathsep)
    path = os.pathsep.join(f for f in folders if not shutil.which("git", path=f))
    result = facts(box, sample, env={"PATH": path})
    assert result.code == 1, str(result)
    assert "handoff" not in result.facts, str(result)
    assert result.has_line("git was not found"), str(result)


def test_never_runs_a_git_in_the_project_folder(box: Sandbox) -> None:
    # On Windows a program search looks in the current folder first. This copy of Python can't
    # even start there, so if it ran, facts.py would fail.
    repo = new_repo(box, "Planted Git", origin="https://github.com/you/planted.git")
    shutil.copyfile(sys.executable, repo / "git.exe")
    result = facts(box, repo)
    assert result.code == 0, str(result)
    assert result.facts["handoff"] == "handoffs/github/you/planted/HANDOFF.md", str(result)


# ---------------------------------------------------------------------------------------------
# The newer-commits topic, which reads the State line of the handoff in the sandbox's dev-home.


def write_handoff(box: Sandbox, name: str, text: str) -> None:
    write_text(box.content / "handoffs" / "github" / "you" / name / "HANDOFF.md", text)


def test_with_no_handoff_yet_says_none_and_unknown(box: Sandbox) -> None:
    repo = new_repo(box, "No Handoff", origin="https://github.com/you/no-handoff.git")
    result = facts(box, repo, "newer-commits")
    assert result.code == 0, str(result)
    assert result.lines == ["checked: none", "newer: unknown", "behind: unknown"], str(result)


def test_counts_lists_and_compares_the_commits_since_the_checked_one(box: Sandbox) -> None:
    repo = new_repo(box, "Newer Repo", origin="https://github.com/you/newer.git", commits=("a",))
    checked = short_head(repo)

    # A State line over two lines: a word of hex letters and a number, neither a commit here,
    # then the checked commit.
    state = (
        "**State as of 2026-01-02.** Checked against `deadbee` and `1234567`, then\n"
        f"against `{checked}`, with 140 tests passing."
    )
    write_handoff(box, "newer", f"# newer handoff\n\n---\n\n{state}\n\n## Next up\n\n- None.\n")
    result = facts(box, repo, "newer-commits")
    assert result.lines == [f"checked: {checked}", "newer: 0", "behind: 0"], str(result)

    for message in ("second", "third"):
        git("-C", str(repo), "commit", "--quiet", "--allow-empty", "-m", f"test: {message}")
    result = facts(box, repo, "newer-commits")
    listed = [line for line in result.lines if line.startswith("newer-commit: ")]
    assert result.facts["newer"] == "2", str(result)
    assert [line.split(" ", 2)[2] for line in listed] == ["test: third", "test: second"]

    for n in range(1, 11):
        git("-C", str(repo), "commit", "--quiet", "--allow-empty", "-m", f"test: more {n}")
    result = facts(box, repo, "newer-commits")
    listed = [line for line in result.lines if line.startswith("newer-commit: ")]
    assert result.facts["newer"] == "12", "counts them all"
    assert len(listed) == 10, "lists at most ten"
    assert listed[0].endswith("test: more 10"), str(result)

    subject = "test: r\u00e9sum\u00e9"
    git("-C", str(repo), "commit", "--quiet", "--allow-empty", "-m", subject)
    result = facts(box, repo, "newer-commits")
    listed = [line for line in result.lines if line.startswith("newer-commit: ")]
    assert listed[0].endswith(f" {subject}"), "reads an accented subject as it is"

    # Naming the latest commit after an earlier one: the latest is the one checked.
    head = short_head(repo)
    write_handoff(
        box,
        "newer",
        f"# newer handoff\n\n**State as of 2026-01-03.** Started from `{checked}`, then "
        f"checked against `{head}`.\n",
    )
    result = facts(box, repo, "newer-commits")
    assert result.lines == [f"checked: {head}", "newer: 0", "behind: 0"], str(result)

    # This checkout falls behind the checked commit, as a PC does before it pulls.
    git("-C", str(repo), "reset", "--quiet", "--hard", "HEAD~2")
    result = facts(box, repo, "newer-commits")
    assert result.lines == [f"checked: {head}", "newer: 0", "behind: 2"], str(result)

    # A commit named in backticks that this checkout doesn't have at all, even beside one it has.
    write_handoff(
        box,
        "newer",
        f"# newer handoff\n\n**State as of 2026-01-04.** Checked against `abc1234`, after "
        f"`{checked}`.\n",
    )
    result = facts(box, repo, "newer-commits")
    expected = ["checked: missing abc1234", "newer: unknown", "behind: unknown"]
    assert result.lines == expected, str(result)

    result = facts(box, repo, "handoff", "environment", "newer-commits")
    assert result.keys[:10] == [
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
    ], str(result)

    # A hash outside the State line doesn't count.
    write_handoff(
        box,
        "newer",
        "# newer handoff\n\n**State as of 2026-01-02.** Nothing checked yet.\n\n## Next up\n\n"
        f"- Start from `{checked}`.\n",
    )
    result = facts(box, repo, "newer-commits")
    assert result.lines == ["checked: none", "newer: unknown", "behind: unknown"], str(result)


def test_when_git_cant_count_says_unknown_and_the_other_topics_print(box: Sandbox) -> None:
    # History git can't walk: the checked commit is there, but one after it is missing.
    repo = new_repo(
        box, "Gap Repo", origin="https://github.com/you/gap.git", commits=("1", "2", "3")
    )
    first = git("-C", str(repo), "rev-parse", "HEAD~2")[0]
    middle = git("-C", str(repo), "rev-parse", "HEAD~1")[0]
    obj = repo / ".git" / "objects" / middle[:2] / middle[2:]
    obj.chmod(0o666)
    obj.unlink()
    write_handoff(box, "gap", f"**State as of 2026-01-02.** Checked against `{first[:7]}`.\n")
    result = facts(box, repo, "handoff", "newer-commits")
    assert result.code == 0, str(result)
    assert result.facts["handoff"] == "handoffs/github/you/gap/HANDOFF.md", str(result)
    assert result.facts["checked"] == first[:7], str(result)
    assert result.facts["newer"] == "unknown", str(result)
    assert result.facts["behind"] == "unknown", str(result)


def test_finds_a_full_sha256_hash_in_the_state_line(box: Sandbox) -> None:
    repo = box.root / "Sha256 Repo"
    git("init", "--quiet", "--object-format=sha256", "-b", "main", str(repo))
    git("-C", str(repo), "remote", "add", "origin", "https://github.com/you/sha256.git")
    git("-C", str(repo), "commit", "--quiet", "--allow-empty", "-m", "test: first")
    long_id = git("-C", str(repo), "rev-parse", "HEAD")[0]
    assert len(long_id) == 64
    write_handoff(box, "sha256", f"**State as of 2026-01-02.** Checked against `{long_id}`.\n")
    result = facts(box, repo, "newer-commits")
    assert result.lines == [f"checked: {long_id[:7]}", "newer: 0", "behind: 0"], str(result)


# ---------------------------------------------------------------------------------------------
# The skill's stamp, and the options.


def test_a_stamp_that_differs_from_the_skill_on_disk_stops_with_why(
    box: Sandbox, sample: Path
) -> None:
    command = skill_command(box, "handoff", "facts.py")
    words = command.split(" ")
    words[words.index("--stamp") + 1] = "000000000000"
    result = run_command(box, " ".join(words), cwd=sample)
    assert result.code == 1, str(result)
    assert result.keys == [], str(result)
    assert result.has_line(r"handoff skill has changed .* run the skill's command again"), str(
        result
    )
    result = run_command(box, command, cwd=sample)
    assert result.code == 0, "the skill's own stamp matches"


def test_options_need_their_values_and_each_other(box: Sandbox, sample: Path) -> None:
    words = skill_command(box, "handoff", "facts.py").split(" ")
    start = words[: words.index("--skill")]
    cases = {
        "--skill handoff handoff": "together",
        "--stamp abc handoff": "together",
        "handoff --skill": "needs a value",
        "--weather handoff": "No such option: --weather",
    }
    for arguments, reason in cases.items():
        result = run_command(box, " ".join([*start, arguments]), cwd=sample)
        assert result.code == 1, f"{arguments}: {result}"
        assert result.has_line(reason), f"{arguments}: {result}"
