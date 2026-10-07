"""Prints facts about where a session is running, for the skills, one topic at a time.

Called by: handoff

Name the topics you want. It prints each topic's lines, as key: value, in the order asked:

    handoff         where the current project's handoff lives in dev-home (six lines)
    environment     the name of the computer the session is on (one line)
    newer-commits   the project's commits since the one its handoff says was checked

It only reports, and only from this PC: it changes nothing and never uses the network, which is
what lets a skill run it without asking first. Anything a skill needs done, rather than told,
goes in a script of its own. A test reads this file for both.

The skills named above rely on each topic's lines as they are. Add a topic freely, but change or
remove a line only after reading every skill that asks for its topic. When you add a skill that
runs this script, add it to the list above (a test compares the two).

With no topic, an unknown one, or a topic that fails, it prints the reason and no facts at all,
and exits 1.

THE SKILL'S STAMP

A skill names itself and its stamp before the topics, as in --skill handoff --stamp 3f9c2ab1d0e4.
Setup stamps each skill when it writes the skill's SKILL.md: the stamp is a fingerprint of the
skill's text, written into the skill's own commands. An agent keeps the text of a skill it has
loaded until the user runs the skill's command again, so when the stamp given differs from the
one in that SKILL.md now, the agent is following steps that have changed since. Then this prints
why, and no facts, and exits 1. Both options are for dev-home-tools' own skills.

prepare.py runs this file's code inside its own process, after a sync that may have brought in a
newer copy of this file than the prepare.py already running. So keep the names and arguments of
what prepare.py calls: parse_request, skill_changed, collect, and FactsError. The handoff skill's
issue_status.py loads it too, for find_handoff_place, find_program, CONTENT_DIR, and FactsError.
And nothing here may change what the whole process shares, such as environment variables or the
current folder, except in the block that runs only when this file is run as a script.

THE HANDOFF TOPIC

Run it in the project's folder. It reads the project's origin address from the project's own git
config, so it needs no network and no sign-in, and prints six lines:

    service: github
    name: you/tool
    handoff: handoffs/github/you/tool/HANDOFF.md
    draft: .drafts/github/you/tool/issue.md
    link: ../dev-home/handoffs/github/you/tool/HANDOFF.md
    project: .

The handoff and draft paths are relative to dev-home. Everything is lowercase, so two PCs whose
addresses differ only in case get the same handoff.

The link is the handoff, and project is the project's folder (the top of this checkout), as link
targets for an agent's replies: an agent links a project file as project, a slash, and the
file's path in the project. Both are percent-encoded like a URL path, so a space becomes %20,
and both take the form that opens where the agent is running:
- In Claude Code's CLI, file:/// URLs, such as file:///C:/Users/you/dev-home/handoffs/...: the
  CLI's terminal opens those, but not a relative path. Claude Code says where it's running in
  CLAUDE_CODE_ENTRYPOINT, which is cli there.
- Everywhere else, paths relative to the current folder: some editors can't open a link to a full
  path that starts with a drive letter. When dev-home is on another drive, there's no relative
  path, so the link is the full path.

A project hosted on a service in SERVICES gets a folder under that service's name, with the rest
of the address after it: <owner>/<repo> for GitHub and Bitbucket, <group>/<project> for GitLab
(plus any subgroups), and <org>/<project>/<repo> for Azure DevOps. HTTPS and SSH addresses give
the same folder.

Any other project is filed by its folder name plus the first 7 characters of its first commit,
such as tools-3f9c2ab. The first commit is the same in every clone, and differs between
unrelated repos, so two projects with the same folder name get separate handoffs. It goes under:
- other: its origin is on a host not in SERVICES, or has a shape the script can't use.
- local: it has no origin, or its origin is a folder rather than a network address.
With no commits yet, in a shallow clone, or outside git, there's no first commit to use, so the
folder name stands alone.

A worktree uses its main checkout's origin and folder name, so it shares that checkout's
handoff.

THE ENVIRONMENT TOPIC

Prints one line, the computer's name as the operating system reports it:

    environment: PC-NAME

A handoff keeps the facts that are true on only one computer under that name, so it has to come
out the same in every session there. On Windows, that's the name Windows itself reports, the
same as COMPUTERNAME, in capitals.

THE NEWER-COMMITS TOPIC

Run it in the project's folder, like the handoff topic, which finds the handoff it reads. It
looks in the handoff's State line, the paragraph that starts "**State as of", for the commit the
last update checked, such as "Checked against `3f9c2ab`", and compares it with this checkout:

    checked: 3f9c2ab
    newer: 2
    behind: 0
    newer-commit: 9d4e1b7 docs: fix a link
    newer-commit: 5a0c3e2 setup: skip a missing folder

newer counts the commits this checkout has that the checked one doesn't, which the handoff may
not reflect yet, and behind counts the ones the checked commit has that this checkout doesn't,
as when another PC pushed work that hasn't been pulled here. One newer-commit line per newer
commit follows, newest first, at most ten, while newer always gives the full count. When the
paragraph names more than one commit this repo has, the checked one is the one with the fewest
commits after it.

checked can also be:
- "none": there's no handoff yet, its State line names no commit, or this isn't a git repo.
- "missing" and a hash: the State line names, in backticks, a commit this checkout doesn't have,
  so it's probably behind. Only a hash with both letters and digits counts, so a plain number or
  a word made of hex letters doesn't.

newer and behind are "unknown" whenever they can't be counted, never "none" or 0, so they can't
be read as "nothing changed". A git failure here never stops the script, so it can't hide where
the handoff is. It reads dev-home's copy as it is, so run it after a sync to compare with the
latest one.

ALL TOPICS

Every line is written as UTF-8, so an accented letter in a name, path, or commit subject reaches
the agent as it is.

Example, shortened: the skills give the full path of python.exe, which is
internal/.python/python.exe in dev-home-tools' folder, and of this script.

    python.exe -I facts.py handoff environment
"""

import functools
import io
import os
import re
import shutil
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote, unquote

# Every topic. To add one, add it here, to the description above, and to the topic functions in
# collect, with a test for its lines.
TOPICS = ("handoff", "environment", "newer-commits")

# The most newer-commit lines the newer-commits topic prints. Its newer line has the full count.
MAX_NEWER_COMMITS = 10

# Hosting services by the host name in a repo's address. To add one, add its hosts here and its
# path shape to service_parts, with a test for each address form it documents.
SERVICES = {
    "github.com": "github",
    "gitlab.com": "gitlab",
    "bitbucket.org": "bitbucket",
    "dev.azure.com": "azure-devops",
    "ssh.dev.azure.com": "azure-devops",
}

# dev-home's folder, filled in by setup.
CONTENT_DIR = "{{CONTENT_DIR}}"

# The generated skills, beside the folder setup writes this script to, so that setup alone
# decides where the generated files go.
GENERATED_SKILLS = Path(__file__).parent.parent / "skills"


class FactsError(Exception):
    """Stops without printing any fact: a guess would file the handoff in the wrong place, and a
    skill given only some of what it asked for could go on as if it had the rest."""


@dataclass(frozen=True)
class Request:
    """What a skill asked for: the topics, and the skill's name and stamp, when it gave them."""

    topics: tuple[str, ...]
    skill: str | None
    stamp: str | None


@dataclass(frozen=True)
class GitResult:
    """What a git command printed: its exit code, its output lines, and its first error line."""

    code: int
    lines: list[str]
    error: str

    @property
    def line(self) -> str:
        return self.lines[0] if self.lines else ""


@dataclass(frozen=True)
class Address:
    """A remote address's host, lowercase, and the path after it."""

    host: str
    path: str


@dataclass(frozen=True)
class HandoffPlace:
    """Where the current project's handoff lives, worked out once for every topic that needs it."""

    service: str
    name: str
    relative: str
    handoff: str
    project_root: str
    in_repo: bool


def parse_request(argv: Sequence[str]) -> Request:
    """Reads the arguments: --skill and --stamp, each with a value, and the topics."""
    values: dict[str, str] = {}
    topics: list[str] = []
    rest = list(argv)
    while rest:
        word = rest.pop(0)
        if word in ("--skill", "--stamp"):
            if not rest:
                raise FactsError(f"{word} needs a value after it.")
            values[word] = rest.pop(0)
        elif word.startswith("-"):
            raise FactsError(f"No such option: {word}. The options are --skill and --stamp.")
        else:
            topics.append(word)
    skill = values.get("--skill")
    stamp = values.get("--stamp")
    if (skill is None) != (stamp is None):
        raise FactsError("Give --skill and --stamp together, or neither.")
    return Request(tuple(topics), skill, stamp)


def skill_changed(request: Request) -> str | None:
    """Why the skill the agent follows is out of date, or None when it matches the one on disk:
    the stamp it was given is the one in the skill's SKILL.md now. See THE SKILL'S STAMP."""
    if request.skill is None or request.stamp is None:
        return None
    name = request.skill
    if not re.fullmatch(r"[a-z0-9-]+", name):
        raise FactsError(f"No skill can be named {name}.")
    path = GENERATED_SKILLS / name / "SKILL.md"
    current = None
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        text = ""
    match = re.search(rf"--skill {re.escape(name)} --stamp ([0-9a-f]+)", text)
    if match:
        current = match.group(1)
    if current == request.stamp:
        return None
    return (
        f"The {name} skill has changed since this session loaded it, so the steps this session "
        f"has for it are out of date. Stop here, and ask the user to run the skill's command "
        f"again, such as /{name} in Claude Code or ${name} in Codex: that loads the new steps, "
        f"with no need for a new session."
    )


@functools.cache
def find_program(name: str) -> str | None:
    """A program's full path, from the folders in PATH. On Windows, a search would look in the
    current folder first, which here is a project's: a program of the same name there must
    never run, so only full paths in PATH count."""
    if sys.platform != "win32":
        return shutil.which(name)
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        if folder and Path(folder).is_absolute():
            candidate = Path(folder) / f"{name}.exe"
            if candidate.is_file():
                return str(candidate)
    return None


def run_git(*args: str, stdin: str = "") -> GitResult:
    """Runs git in the current folder, reading its output as UTF-8. Git's messages are in
    English, so "not a git repository" can be told apart from other failures. Only git's own
    environment changes, since this may run inside prepare.py's process."""
    git = find_program("git") or "git"
    done = subprocess.run(
        [git, *args],
        input=stdin,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=os.environ | {"LC_ALL": "C"},
        check=False,
    )
    lines = [line.strip() for line in done.stdout.splitlines()]
    errors = [line.strip() for line in done.stderr.splitlines() if line.strip()]
    return GitResult(done.returncode, lines, errors[0] if errors else "")


DRIVE_PATH = re.compile(r"^[A-Za-z]:[\\/]")
# https://host/path, ssh://user@host:port/path, and the like.
URL_ADDRESS = re.compile(
    r"^[A-Za-z][A-Za-z0-9+.-]*://(?:[^@/]*@)?(?P<host>[^/:@]+)(?::\d+)?/(?P<path>.+)$"
)
# user@host:path, the short form SSH addresses use. A path after the colon never starts with a
# slash, which keeps out drive paths such as C:/repos/tool.
SCP_ADDRESS = re.compile(r"^(?:[^@/:]+@)?(?P<host>[^/:@]+):(?P<path>[^/].*)$")


def split_address(address: str) -> Address | None:
    """Splits a remote address into its host and the path after it, dropping any scheme, user
    name, port, and trailing .git. Returns None for anything else, such as a local path."""
    # A drive path, such as C:\repos\tool, would otherwise look like host:path below.
    if DRIVE_PATH.match(address):
        return None
    match = URL_ADDRESS.match(address) or SCP_ADDRESS.match(address)
    if not match:
        return None
    path = match.group("path").rstrip("/")
    if path.lower().endswith(".git"):
        path = path[:-4]
    return Address(match.group("host").lower(), path)


def service_parts(service: str, path: str) -> list[str] | None:
    """The folder names for a service's repo, from the path in its address. Returns None when
    the path doesn't have that service's usual shape."""
    # Decoded before splitting, so an encoded slash can't hide a segment from the checks below.
    parts = unquote(path).lower().split("/")
    if service == "azure-devops":
        # SSH addresses read v3/<org>/<project>/<repo>, and HTTPS ones <org>/<project>/_git/<repo>.
        # The short HTTPS form <org>/_git/<repo> is for a repo named the same as its project.
        if parts[0] == "v3":
            parts.pop(0)
        if "_git" in parts:
            at = parts.index("_git")
            parts.pop(at)
            if at == 1 and len(parts) == 2:
                parts.insert(1, parts[1])
        if len(parts) != 3:
            return None
    elif service == "gitlab":
        if len(parts) < 2:
            return None
    elif len(parts) != 2:
        return None
    if not all(is_folder_name(part) for part in parts):
        return None
    return parts


def is_folder_name(name: str) -> bool:
    """True when a name is safe as one folder in dev-home: no path tricks, and nothing Windows
    refuses in a folder name."""
    if not name.strip() or name in (".", ".."):
        return False
    if re.search(r'[\x00-\x1f<>:"/\\|?*]', name):
        return False
    if name.endswith((".", " ")):
        return False
    return not re.fullmatch(r"(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?", name, re.IGNORECASE)


def first_commit_id() -> str | None:
    """The first 7 characters of the first commit on the main line. Following first parents
    gives one answer even when unrelated histories were merged in. Returns None with no commits
    yet, and in a shallow clone, whose oldest commit is only where the download stopped."""
    shallow = run_git("rev-parse", "--is-shallow-repository")
    if shallow.code != 0:
        raise FactsError(f"git could not read this repo. git: {shallow.error}")
    if shallow.line == "true":
        return None
    # Exit code 1, with --quiet, means there are no commits yet.
    head = run_git("rev-parse", "--verify", "--quiet", "HEAD")
    if head.code == 1:
        return None
    if head.code != 0:
        raise FactsError(f"git could not read this repo's commits. git: {head.error}")
    first = run_git("rev-list", "--first-parent", "--max-parents=0", "HEAD")
    if first.code != 0 or not re.fullmatch(r"[0-9a-f]{40,64}", first.line):
        raise FactsError(f"git could not find this repo's first commit. git: {first.error}")
    return first.line[:7]


def link_target(path: str) -> str:
    """Percent-encodes a forward-slash path the way a URL path is written, so it works as a
    markdown link's target: a space becomes %20. Letters, digits, and the marks a URL path allows
    stay as they are, except parentheses, which could end the link early. A drive letter stays
    too."""
    parts = []
    for part in path.split("/"):
        if re.fullmatch(r"[A-Za-z]:", part):
            parts.append(part)
        else:
            parts.append(quote(part, safe="!$&'*+,;=@"))
    return "/".join(parts)


def file_url(path: str) -> str:
    """A full path as a file:/// URL, percent-encoded as link_target does. A network path, such
    as //server/share, becomes file://server/share."""
    full = os.path.abspath(path).replace("\\", "/").rstrip("/")
    if full.startswith("//"):
        return "file:" + link_target(full)
    return "file:///" + link_target(full)


def relative_to_here(path: str) -> str:
    """A path relative to the current folder, with forward slashes, or the full path when it's
    on another drive and there's no relative one."""
    try:
        relative = os.path.relpath(path, Path.cwd())
    except ValueError:
        relative = os.path.abspath(path)
    return relative.replace("\\", "/")


def find_handoff_place() -> HandoffPlace:
    """Where the current project's handoff lives. Stops when it can't be told for sure."""
    if find_program("git") is None:
        raise FactsError(
            "git was not found, so the handoff can't be found. Install Git, or add it to PATH."
        )

    # The project's folder: the one holding the main .git, so a worktree gets its main checkout's
    # name. Outside a git repo, the current folder. Any other failure stops the script, because
    # treating a repo git can't read as a plain folder would give the wrong handoff.
    here = Path.cwd()
    folder = here.name
    common = run_git("rev-parse", "--path-format=absolute", "--git-common-dir")
    in_repo = common.code == 0 and bool(common.line)
    if in_repo:
        folder = Path(common.line).parent.name
    elif "not a git repository" not in common.error.lower():
        raise FactsError(
            f"git could not read this folder, so the handoff can't be found. git: {common.error}"
        )

    folder_name = folder.lower()
    if not is_folder_name(folder_name):
        raise FactsError(
            f'No handoff can be named after the folder "{folder}". Run this in a project folder.'
        )

    # Where the project is hosted, from its origin address.
    service = "local"
    parts: list[str] | None = None
    if in_repo:
        # Exit code 2 means there's no origin.
        origin = run_git("remote", "get-url", "origin")
        if origin.code not in (0, 2):
            raise FactsError(f"git could not read this project's origin. git: {origin.error}")
        address = split_address(origin.line) if origin.code == 0 and origin.line else None
        if address is not None:
            service = "other"
            known = SERVICES.get(address.host)
            found = service_parts(known, address.path) if known else None
            if known and found is not None:
                service = known
                parts = found

    # Not on a service in the list: the folder name, and the first commit when there is one.
    if parts is None:
        first = first_commit_id() if in_repo else None
        parts = [f"{folder_name}-{first}" if first else folder_name]

    relative = "/".join([service, *parts])

    # The project's folder: the top of this checkout, or the current folder outside one, such as
    # in a bare repo.
    project_root = str(here)
    if in_repo:
        top = run_git("rev-parse", "--show-toplevel")
        if top.code == 0 and top.line:
            project_root = top.line

    return HandoffPlace(
        service=service,
        name="/".join(parts),
        relative=relative,
        handoff=f"handoffs/{relative}/HANDOFF.md",
        project_root=project_root,
        in_repo=in_repo,
    )


def handoff_lines(place: HandoffPlace) -> list[str]:
    """The handoff topic's six lines."""
    handoff_path = f"{CONTENT_DIR}/{place.handoff}"
    if os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "cli":
        link = file_url(handoff_path)
        project = file_url(place.project_root)
    else:
        link = link_target(relative_to_here(handoff_path))
        project = link_target(relative_to_here(place.project_root))
    return [
        f"service: {place.service}",
        f"name: {place.name}",
        f"handoff: {place.handoff}",
        f"draft: .drafts/{place.relative}/issue.md",
        f"link: {link}",
        f"project: {project}",
    ]


def computer_name() -> str:
    """The operating system's own name for the computer. On Windows, the name Windows reports,
    the same as COMPUTERNAME, rather than the network name, which can differ in case."""
    if sys.platform == "win32":
        import ctypes

        buffer = ctypes.create_unicode_buffer(256)
        size = ctypes.c_ulong(len(buffer))
        if not ctypes.WinDLL("kernel32").GetComputerNameW(buffer, ctypes.byref(size)):
            raise FactsError("Windows could not report this computer's name.")
        return buffer.value
    return os.uname().nodename.split(".")[0]


def environment_lines() -> list[str]:
    """The environment topic's one line."""
    return [f"environment: {computer_name()}"]


STATE_LINE = re.compile(r"^\*\*State as of", re.IGNORECASE)
# Lowercase hex as git prints it, from a 7-character short hash to a full SHA-256 one, standing
# apart from any word or number.
COMMIT_HASH = re.compile(r"(?<![0-9A-Za-z])[0-9a-f]{7,64}(?![0-9A-Za-z])")


def state_paragraph(text: str) -> str:
    """The handoff's State line: the paragraph that starts "**State as of", joined into one
    line, or empty text when there is none."""
    lines = text.replace("\r\n", "\n").split("\n")
    for start, line in enumerate(lines):
        if STATE_LINE.match(line):
            paragraph = []
            for next_line in lines[start:]:
                if not next_line.strip():
                    break
                paragraph.append(next_line)
            return " ".join(paragraph)
    return ""


def named_commits(text: str) -> tuple[list[str], list[str]]:
    """The commits named in a handoff's State line, where an update records what it checked,
    such as "Checked against `3f9c2ab`". Returns the full hash of each one this repo has, in the
    order named and each once, and each hash in backticks that this repo doesn't have. A hash
    elsewhere in the handoff doesn't count."""
    paragraph = state_paragraph(text)
    matches = list(COMMIT_HASH.finditer(paragraph))
    if not matches:
        return [], []
    # One git process for every hash: each answer is the full hash and "commit", "missing", or
    # "ambiguous" for a short hash that matches more than one object.
    check = run_git(
        "cat-file", "--batch-check", stdin="".join(m.group() + "^{commit}\n" for m in matches)
    )
    if check.code != 0 or len(check.lines) != len(matches):
        return [], []
    found: list[str] = []
    missing: list[str] = []
    for match, answer in zip(matches, check.lines, strict=True):
        words = answer.split()
        if len(words) >= 2 and words[1] == "commit" and re.fullmatch(r"[0-9a-f]{40,64}", words[0]):
            if words[0] not in found:
                found.append(words[0])
            continue
        # Counted as a hash this checkout lacks only when written as an update writes one: in
        # backticks, with both letters and digits. A plain number, or a word such as `deadbee`,
        # isn't taken for one.
        value = match.group()
        quoted = paragraph[match.start() - 1 : match.start()] == "`" and (
            paragraph[match.end() : match.end() + 1] == "`"
        )
        has_both = re.search(r"[a-f]", value) and re.search(r"[0-9]", value)
        if answer.endswith(" missing") and quoted and has_both:
            missing.append(value)
    return found, missing


def count_both_ways(commit: str) -> tuple[int, int] | None:
    """How many commits the given one has that this checkout doesn't (behind), and how many this
    checkout has that it doesn't (newer), or None when git can't count them."""
    counts = run_git("rev-list", "--left-right", "--count", f"{commit}...HEAD")
    match = re.fullmatch(r"(\d+)\s+(\d+)", counts.line)
    if counts.code != 0 or not match:
        return None
    return int(match.group(1)), int(match.group(2))


def newer_commit_lines(place: HandoffPlace) -> list[str]:
    """The newer-commits topic's lines. A count that can't be told is unknown, never none or 0,
    so it can't be read as "nothing changed". A git failure here never stops the script, because
    the other topics, which say where the handoff is, matter more than this one."""
    found: list[str] = []
    missing: list[str] = []
    if place.in_repo:
        try:
            text = (Path(CONTENT_DIR) / place.handoff).read_text(encoding="utf-8-sig")
        except (OSError, UnicodeDecodeError):
            text = ""
        found, missing = named_commits(text)

    # A commit the update knew of that this checkout lacks means the checkout is probably behind,
    # even when the State line also names one it has: pulling is the safe advice.
    if missing:
        return [f"checked: missing {missing[0][:7]}", "newer: unknown", "behind: unknown"]
    if not found:
        return ["checked: none", "newer: unknown", "behind: unknown"]

    # A State line can name more than one commit, such as an earlier one in passing. The one with
    # the fewest commits after it is the latest the update knew of.
    best: tuple[str, int, int] | None = None
    for commit in found:
        counts = count_both_ways(commit)
        if counts is not None and (best is None or counts[1] < best[2]):
            best = (commit, counts[0], counts[1])
    if best is None:
        return [f"checked: {found[0][:7]}", "newer: unknown", "behind: unknown"]

    commit, behind, newer = best
    lines = [f"checked: {commit[:7]}", f"newer: {newer}", f"behind: {behind}"]
    if newer > 0:
        listing = run_git(
            "rev-list", "--oneline", f"--max-count={MAX_NEWER_COMMITS}", f"{commit}..HEAD"
        )
        if listing.code == 0:
            lines.extend(f"newer-commit: {line}" for line in listing.lines if line)
    return lines


def collect(topics: Sequence[str]) -> list[str]:
    """Every line of the topics asked for, in the order asked. Checks the topics first, then
    works every one out before returning any, so a skill never gets only part of what it asked
    for. Raises FactsError instead."""
    asked = list(dict.fromkeys(topic.lower() for topic in topics if topic))
    if not asked:
        raise FactsError(f"Name at least one topic: {', '.join(TOPICS)}.")
    unknown = [topic for topic in asked if topic not in TOPICS]
    if unknown:
        raise FactsError(
            f"No such topic: {', '.join(unknown)}. The topics are: {', '.join(TOPICS)}."
        )

    place: HandoffPlace | None = None

    def handoff_place() -> HandoffPlace:
        nonlocal place
        if place is None:
            place = find_handoff_place()
        return place

    topic_lines: dict[str, Callable[[], list[str]]] = {
        "handoff": lambda: handoff_lines(handoff_place()),
        "environment": environment_lines,
        "newer-commits": lambda: newer_commit_lines(handoff_place()),
    }
    lines: list[str] = []
    for topic in asked:
        lines.extend(topic_lines[topic]())
    return lines


def main(argv: Sequence[str]) -> int:
    """Prints the facts asked for, or the reason there are none and exits 1."""
    try:
        request = parse_request(argv)
        changed = skill_changed(request)
        if changed is not None:
            print(changed, file=sys.stderr)
            return 1
        lines = collect(request.topics)
    except FactsError as error:
        print(error, file=sys.stderr)
        return 1
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    # Agents read UTF-8, but Python writes the console's code page when its output is redirected.
    for stream in (sys.stdout, sys.stderr):
        if isinstance(stream, io.TextIOWrapper):
            stream.reconfigure(encoding="utf-8")
    sys.exit(main(sys.argv[1:]))
