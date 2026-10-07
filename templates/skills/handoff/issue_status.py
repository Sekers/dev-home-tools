"""Says whether each GitHub issue the current project's handoff links to is open or closed.

The handoff skill's update runs it in the project's folder, in the same turn as its read of the
handoff just before editing it. It finds the handoff as facts.py's handoff topic does, takes each
link of the form https://github.com/<owner>/<repo>/issues/<number> once, in the order the links
come, and asks GitHub about all of them in one gh request. It prints one line for each:

    OPEN      https://github.com/you/tool/issues/12
    CLOSED    https://github.com/you/tool/issues/7 (completed)
    UNCHECKED https://github.com/gone/repo/issues/1 (GitHub didn't return it: Could not ...)

A closed issue's reason is GitHub's: completed, not planned, or duplicate, and none when GitHub
gives none. UNCHECKED says why: gh missing or signed out, gh failing, such as offline, or GitHub
not returning that issue, such as one in a repo that's gone. With no issue links, it prints one
line:

    OK        The handoff links no GitHub issues.

It prints a PROBLEM line instead when the handoff can't be found, or the script stops. It always
exits 0: everything it has to say is in its lines. It changes nothing: the one program it starts
is gh, with a GraphQL query that only reads. It takes no --skill or --stamp, because the update's
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

# The generated facts.py, filled in by setup.
FACTS = "{{SHARED_SKILL_SCRIPTS_DIR}}/facts.py"

# A link to a GitHub issue. Owner and repo keep to the characters GitHub allows in a name, so
# they go into the query as they are, and the number stays well inside GraphQL's Int.
ISSUE_LINK = re.compile(
    r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([1-9][0-9]{0,8})(?![0-9])"
)
# What gh exits with when it isn't signed in.
GH_SIGNED_OUT = 4
GH_TIMEOUT_SECONDS = 60


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
    """Each issue the text links to, once, in the order they first come. GitHub's names ignore
    case, so two links that differ only in case are one issue."""
    issues: dict[tuple[str, str, int], Issue] = {}
    for match in ISSUE_LINK.finditer(text):
        owner, repo, number = match.group(1), match.group(2), int(match.group(3))
        key = (owner.lower(), repo.lower(), number)
        if key not in issues:
            issues[key] = Issue(match.group(0), owner, repo, number)
    return list(issues.values())


def query(issues: list[Issue]) -> str:
    """One GraphQL query that only reads, with each issue under an alias of its own: i0, i1, and
    so on."""
    parts = [
        f'i{n}: repository(owner: "{issue.owner}", name: "{issue.repo}") '
        f"{{ issue(number: {issue.number}) {{ state stateReason }} }}"
        for n, issue in enumerate(issues)
    ]
    return "query { " + " ".join(parts) + " }"


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


def check_links(issues: list[Issue], gh: str | None) -> list[str]:
    """A line for each issue. GitHub answers for every alias it can, and lists an error for each
    one it can't, so one missing repo leaves the others' answers in place."""
    if gh is None:
        return unchecked(issues, "gh, the GitHub CLI, isn't installed, or isn't in PATH")
    result = run_gh(gh, query(issues))
    if result.code == GH_SIGNED_OUT:
        return unchecked(issues, "gh isn't signed in to GitHub: the user runs gh auth login")
    try:
        answer = json.loads(result.out)
    except ValueError:
        answer = None
    data = answer.get("data") if isinstance(answer, dict) else None
    if not isinstance(answer, dict) or not isinstance(data, dict):
        return unchecked(issues, f"gh failed: {first_line(result.err) or 'it gave no answer'}")

    errors: dict[str, str] = {}
    for error in answer.get("errors") or []:
        path = error.get("path") if isinstance(error, dict) else None
        if isinstance(path, list) and path and isinstance(path[0], str):
            errors.setdefault(path[0], str(error.get("message") or ""))

    lines: list[str] = []
    for n, issue in enumerate(issues):
        node = data.get(f"i{n}")
        found = node.get("issue") if isinstance(node, dict) else None
        state = found.get("state") if isinstance(found, dict) else None
        if isinstance(found, dict) and state == "OPEN":
            lines.append(status_line("OPEN", issue.url))
        elif isinstance(found, dict) and state == "CLOSED":
            reason = found.get("stateReason")
            why = f" ({reason.lower().replace('_', ' ')})" if isinstance(reason, str) else ""
            lines.append(status_line("CLOSED", issue.url + why))
        else:
            message = errors.get(f"i{n}")
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
