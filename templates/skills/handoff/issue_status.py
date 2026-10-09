"""Says whether each GitHub issue the current project's handoff links to is open or closed.

The handoff skill's update runs it in the project's folder, in the same turn as its read of the
handoff just before editing it. It finds the handoff as facts.py's handoff topic does, takes each
link of the form https://github.com/<owner>/<repo>/issues/<number> once, in the order the links
come, and asks GitHub about all of them in one gh request. It leaves out a link after "See also:"
in its item, which the handoff keeps only for what that issue holds, so its state never matters.
An item ends at the next line that starts an item, a heading, or a new paragraph. It prints one
line for each issue it checks:

    OPEN      https://github.com/you/tool/issues/12
    CLOSED    https://github.com/you/tool/issues/7 (completed)
    CLOSED    https://github.com/you/tool/issues/9 (duplicate of https://github.com/you/tool/
              issues/4, which is open: Imports fail on large files)
    CLOSED    https://github.com/other/lib/issues/3 (not planned, by octocat on 2026-10-01)
    COMMENT   https://github.com/other/lib/issues/3 octocat on 2026-10-01: Moved to #20.
    UNCHECKED https://github.com/gone/repo/issues/1 (GitHub didn't return it: Could not ...)

(The duplicate's line is one line; it's split here to fit.) A closed issue's reason is GitHub's:
completed, not planned, or duplicate, and none when GitHub gives none. A duplicate's line names
the issue it duplicates, that issue's state, and its title, so the handoff can link to it
instead. When any issue closed as not planned, a second gh request asks who closed each one and
when, and its last three comments: its line says who and when, "you" when it was the account gh
is signed in to, and a COMMENT line follows for each comment, oldest first, on one line and cut
after 500 characters, or one saying "(no comments)". UNCHECKED says why: gh missing or signed
out, gh failing, such as offline, or GitHub not returning that issue, such as one in a repo
that's gone. With no issue links, it prints one line:

    OK        The handoff links no GitHub issues.

It prints a PROBLEM line instead when the handoff can't be found, or the script stops. It always
exits 0: everything it has to say is in its lines. It changes nothing: the one program it starts
is gh, with GraphQL queries that only read. It takes no --skill or --stamp, because the update's
start-up command has just checked the skill's stamp.

It loads the generated facts.py by its path, as prepare.py does, and uses its
find_handoff_place, find_program, CONTENT_DIR, and FactsError, so facts.py keeps those names.

Example, shortened: the skill gives the full path of python.exe, which is
internal/.python/python.exe in dev-home-tools' folder, and of this script.

    python.exe -I issue_status.py
"""

import importlib.util
import io
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any

# The generated facts.py, filled in by setup.
FACTS = "{{SHARED_SKILL_SCRIPTS_DIR}}/facts.py"

# A link to a GitHub issue. Owner and repo keep to the characters GitHub allows in a name, so
# they go into the query as they are, and the number stays well inside GraphQL's Int.
ISSUE_LINK = re.compile(
    r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([1-9][0-9]{0,8})(?![0-9])"
)
# Links after "See also:" are kept for what those issues hold, until the end of the item: the
# next line that starts an item, a heading, or a new paragraph.
SEE_ALSO = re.compile(r"see also:", re.IGNORECASE)
ITEM_START = re.compile(r"^\s*(?:[-*+]\s|\d+[.)]\s|#|$)")
# What gh exits with when it isn't signed in.
GH_SIGNED_OUT = 4
GH_TIMEOUT_SECONDS = 60
# How many of an issue's last comments a not-planned close prints, and how much of each.
COMMENTS = 3
COMMENT_CHARACTERS = 500


@dataclass(frozen=True)
class Issue:
    """One linked issue: the link as the handoff writes it, and the parts GitHub needs."""

    url: str
    owner: str
    repo: str
    number: int


@dataclass(frozen=True)
class GhResult:
    """What gh printed, and its exit code."""

    code: int
    out: str
    err: str


@dataclass(frozen=True)
class Answer:
    """GitHub's answer to one query: each alias's data, and GitHub's error for each alias it
    couldn't answer. failed says why there's no answer at all, such as gh signed out."""

    data: dict[str, Any]
    errors: dict[str, str]
    failed: str = ""


def status_line(state: str, message: str) -> str:
    """A line in the format the sync's status lines have."""
    return f"{state:<9} {message}"


def first_line(text: str) -> str:
    return next((line.strip() for line in text.splitlines() if line.strip()), "")


def load_facts() -> ModuleType:
    """Loads facts.py by its path: python -I leaves this script's folder off the import path."""
    spec = importlib.util.spec_from_file_location("dev_home_facts", FACTS)
    if spec is None or spec.loader is None:
        raise ImportError(f"{FACTS} could not be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def find_gh(facts: ModuleType) -> str | None:
    """gh's full path, found as facts.py finds git: never in the current folder, a project's."""
    found: str | None = facts.find_program("gh")
    return found


def issue_links(text: str) -> list[Issue]:
    """Each issue the text links to, once, in the order they first come, leaving out links after
    "See also:" in their item. GitHub's names ignore case, so two links that differ only in case
    are one issue."""
    issues: dict[tuple[str, str, int], Issue] = {}
    see_also = False
    for line in text.splitlines():
        if ITEM_START.match(line):
            see_also = False
        marker = SEE_ALSO.search(line)
        for match in ISSUE_LINK.finditer(line):
            if see_also or (marker is not None and match.start() > marker.start()):
                continue
            owner, repo, number = match.group(1), match.group(2), int(match.group(3))
            key = (owner.lower(), repo.lower(), number)
            if key not in issues:
                issues[key] = Issue(match.group(0), owner, repo, number)
        see_also = see_also or marker is not None
    return list(issues.values())


def query(issues: list[Issue]) -> str:
    """One GraphQL query that only reads, with each issue under an alias of its own: i0, i1, and
    so on. A duplicate brings the issue it duplicates."""
    parts = [
        f'i{n}: repository(owner: "{issue.owner}", name: "{issue.repo}") '
        f"{{ issue(number: {issue.number}) {{ state stateReason "
        "duplicateOf { url title state stateReason } } }"
        for n, issue in enumerate(issues)
    ]
    return "query { " + " ".join(parts) + " }"


def close_query(issues: list[Issue]) -> str:
    """The second query, for issues closed as not planned: who closed each and when, and its last
    comments, under the aliases c0, c1, and so on, with the signed-in account's name."""
    parts = [
        f'c{n}: repository(owner: "{issue.owner}", name: "{issue.repo}") '
        f"{{ issue(number: {issue.number}) {{ "
        "timelineItems(last: 1, itemTypes: [CLOSED_EVENT]) "
        "{ nodes { ... on ClosedEvent { createdAt actor { login } } } } "
        f"comments(last: {COMMENTS}) {{ nodes {{ createdAt author {{ login }} body }} }} }} }}"
        for n, issue in enumerate(issues)
    ]
    return "query { viewer { login } " + " ".join(parts) + " }"


def run_gh(gh: str, text: str) -> GhResult:
    """Sends the query through gh, reading its output as UTF-8. gh is told never to ask anything,
    and only its own environment changes, since this may run inside another program's process."""
    try:
        done = subprocess.run(
            [gh, "api", "graphql", "-f", f"query={text}"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            env=os.environ | {"GH_PROMPT_DISABLED": "1"},
            timeout=GH_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return GhResult(1, "", f"gh didn't answer within {GH_TIMEOUT_SECONDS} seconds")
    except OSError as error:
        return GhResult(1, "", f"gh could not start: {error}")
    return GhResult(done.returncode, done.stdout, done.stderr)


def unchecked(issues: list[Issue], why: str) -> list[str]:
    return [status_line("UNCHECKED", f"{issue.url} ({why})") for issue in issues]


def ask(gh: str, text: str) -> Answer:
    """Sends a query and reads GitHub's answer. GitHub answers for every alias it can, and lists
    an error for each one it can't, so one missing repo leaves the others' answers in place."""
    result = run_gh(gh, text)
    if result.code == GH_SIGNED_OUT:
        return Answer({}, {}, "gh isn't signed in to GitHub: the user runs gh auth login")
    try:
        answer = json.loads(result.out)
    except ValueError:
        answer = None
    data = answer.get("data") if isinstance(answer, dict) else None
    if not isinstance(answer, dict) or not isinstance(data, dict):
        return Answer({}, {}, f"gh failed: {first_line(result.err) or 'it gave no answer'}")
    errors: dict[str, str] = {}
    for error in answer.get("errors") or []:
        path = error.get("path") if isinstance(error, dict) else None
        if isinstance(path, list) and path and isinstance(path[0], str):
            errors.setdefault(path[0], str(error.get("message") or ""))
    return Answer(data, errors)


def issue_in(answer: Answer, alias: str) -> dict[str, Any] | None:
    """The issue GitHub returned under an alias, or None."""
    node = answer.data.get(alias)
    found = node.get("issue") if isinstance(node, dict) else None
    return found if isinstance(found, dict) else None


def nodes(connection: object) -> list[dict[str, Any]]:
    """The items of a list GitHub returned, such as an issue's comments."""
    items = connection.get("nodes") if isinstance(connection, dict) else None
    return [item for item in items or [] if isinstance(item, dict)]


def reason_words(reason: object) -> str:
    """GitHub's reason for a close as words, such as "not planned", or empty text for none."""
    return reason.lower().replace("_", " ") if isinstance(reason, str) else ""


def one_line(text: str) -> str:
    return " ".join(text.split())


def duplicate_words(original: object) -> str:
    """What a duplicate's line says about the issue it duplicates: its link, its state, and its
    title. Just "duplicate" when GitHub doesn't say which."""
    if not isinstance(original, dict) or not isinstance(original.get("url"), str):
        return "duplicate"
    if original.get("state") == "OPEN":
        where = "open"
    else:
        reason = reason_words(original.get("stateReason"))
        where = f"closed as {reason}" if reason else "closed"
    title = one_line(str(original.get("title") or ""))
    return f"duplicate of {original['url']}, which is {where}: {title}"


def who(account: object, viewer: str) -> str:
    """An actor or a comment's author by name: "you" for the account gh is signed in to."""
    login = account.get("login") if isinstance(account, dict) else None
    if not isinstance(login, str) or not login:
        return "an account that's gone"
    return "you" if login == viewer else login


def day(item: dict[str, Any]) -> str:
    when = item.get("createdAt")
    return when[:10] if isinstance(when, str) else "an unknown date"


def not_planned_lines(issue: Issue, closes: Answer, alias: str) -> list[str]:
    """An issue closed as not planned: who closed it and when, then a COMMENT line for each of
    its last comments."""
    found = issue_in(closes, alias)
    if found is None:
        why = closes.failed or closes.errors.get(alias) or "GitHub didn't return it"
        return [
            status_line(
                "CLOSED",
                f"{issue.url} (not planned; who closed it, and why, couldn't be read: {why})",
            )
        ]
    viewer_node = closes.data.get("viewer")
    viewer = str(viewer_node.get("login") or "") if isinstance(viewer_node, dict) else ""
    closed = "not planned"
    events = nodes(found.get("timelineItems"))
    if events:
        closed += f", by {who(events[-1].get('actor'), viewer)} on {day(events[-1])}"
    lines = [status_line("CLOSED", f"{issue.url} ({closed})")]
    comments = nodes(found.get("comments"))
    if not comments:
        lines.append(status_line("COMMENT", f"{issue.url} (no comments)"))
    for comment in comments:
        body = one_line(str(comment.get("body") or ""))
        if len(body) > COMMENT_CHARACTERS:
            body = body[:COMMENT_CHARACTERS] + "... (cut)"
        author = who(comment.get("author"), viewer)
        lines.append(status_line("COMMENT", f"{issue.url} {author} on {day(comment)}: {body}"))
    return lines


def check_links(issues: list[Issue], gh: str | None) -> list[str]:
    """A line for each issue, with COMMENT lines after each one closed as not planned."""
    if gh is None:
        return unchecked(issues, "gh, the GitHub CLI, isn't installed, or isn't in PATH")
    answer = ask(gh, query(issues))
    if answer.failed:
        return unchecked(issues, answer.failed)
    found = [issue_in(answer, f"i{n}") for n in range(len(issues))]

    # Only issues closed as not planned need the second request.
    not_planned = [
        issue
        for issue, node in zip(issues, found, strict=True)
        if node is not None
        and node.get("state") == "CLOSED"
        and node.get("stateReason") == "NOT_PLANNED"
    ]
    aliases = {issue.url: f"c{n}" for n, issue in enumerate(not_planned)}
    closes = ask(gh, close_query(not_planned)) if not_planned else Answer({}, {})

    lines: list[str] = []
    for n, (issue, node) in enumerate(zip(issues, found, strict=True)):
        state = node.get("state") if node is not None else None
        if node is not None and state == "OPEN":
            lines.append(status_line("OPEN", issue.url))
        elif node is not None and state == "CLOSED":
            reason = node.get("stateReason")
            if reason == "NOT_PLANNED":
                lines.extend(not_planned_lines(issue, closes, aliases[issue.url]))
                continue
            words = reason_words(reason)
            if reason == "DUPLICATE":
                words = duplicate_words(node.get("duplicateOf"))
            lines.append(status_line("CLOSED", issue.url + (f" ({words})" if words else "")))
        else:
            message = answer.errors.get(f"i{n}")
            detail = f": {message}" if message else ""
            lines.append(status_line("UNCHECKED", f"{issue.url} (GitHub didn't return it{detail})"))
    return lines


def main() -> int:
    """Prints a line for each issue the handoff links to. Always returns 0."""
    try:
        facts = load_facts()
        try:
            place = facts.find_handoff_place()
        except facts.FactsError as error:
            lines = [
                status_line(
                    "PROBLEM", f"No issue was checked, because the handoff can't be found: {error}"
                )
            ]
        else:
            try:
                text = (Path(facts.CONTENT_DIR) / place.handoff).read_text(encoding="utf-8-sig")
            except FileNotFoundError:
                text = ""
            issues = issue_links(text)
            if issues:
                lines = check_links(issues, find_gh(facts))
            else:
                lines = [status_line("OK", "The handoff links no GitHub issues.")]
    except Exception as error:
        # Every failure becomes a line, so the agent always gets one to act on.
        lines = [
            status_line(
                "PROBLEM",
                f"issue_status.py stopped, so no issue was checked: {type(error).__name__}: "
                f"{error}",
            )
        ]
    print("\n".join(lines), flush=True)
    return 0


if __name__ == "__main__":
    # Agents read UTF-8, but Python writes the console's code page when its output is redirected.
    for stream in (sys.stdout, sys.stderr):
        if isinstance(stream, io.TextIOWrapper):
            stream.reconfigure(encoding="utf-8")
    sys.exit(main())
