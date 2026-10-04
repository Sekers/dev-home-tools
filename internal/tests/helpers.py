"""What the tests share: sandboxes, running scripts as agents run them, and reading scripts' code.

A test never runs the scripts in this repo. It builds a sandbox under .test-sandbox/, which git
ignores: a copy of this repo's working tree (uncommitted changes included), a scratch profile, a
dev-home with some content, and local bare repos standing in for GitHub. The copy's
local-settings.json sets testHomeDir before anything in the copy runs, so every setup run from
it, including the ones sync.ps1 and update.ps1 start, uses the scratch profile instead of the
real one. run refuses a script outside a sandbox. Nothing here uses the network or GitHub.

The skills' commands are taken word for word from the sandbox's generated skills. They start
with .python/python.exe, a junction setup makes. A virtual environment's python.exe can't run
through a junction, so the tests start each command with this environment's own Python instead,
by its real path, which lets coverage measure the scripts. One test runs a command unchanged.
"""

import ast
import contextlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import uuid
from collections.abc import Callable, Iterator, Mapping
from dataclasses import dataclass, field
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SANDBOX_ROOT = REPO_ROOT / ".test-sandbox"

# What a sandbox's copy leaves out: PC-specific files, and the development tools' own.
# Invoke-Tests.ps1 has the same list.
NOT_COPIED = {
    ".git",
    ".generated",
    "local-settings.json",
    ".test-sandbox",
    ".python",
    ".venv",
    ".pytest_cache",
    ".ruff_cache",
    ".mypy_cache",
    ".coverage",
    "htmlcov",
}


@dataclass(frozen=True)
class Sandbox:
    """A sandbox's folders. tools is the copy of this repo, and content its dev-home."""

    root: Path

    @property
    def tools(self) -> Path:
        return self.root / "tools"

    @property
    def profile(self) -> Path:
        return self.root / "profile"

    @property
    def content(self) -> Path:
        return self.root / "dev-home"

    @property
    def remote(self) -> Path:
        return self.root / "dev-home-remote.git"

    @property
    def tools_remote(self) -> Path:
        return self.root / "tools-remote.git"

    @property
    def generated(self) -> Path:
        return self.tools / ".generated"

    @property
    def python_bin(self) -> Path:
        """Where setup looks for the Python install manager's shortcuts in this profile."""
        return self.profile / "AppData" / "Local" / "Python" / "bin"


@dataclass(frozen=True)
class Run:
    """A finished run: its exit code, and its output and errors as lines, read as UTF-8."""

    code: int
    lines: list[str]
    facts: dict[str, str] = field(init=False)
    keys: list[str] = field(init=False)

    def __post_init__(self) -> None:
        # Each "key: value" line. A key printed more than once keeps its last value.
        facts: dict[str, str] = {}
        keys: list[str] = []
        for line in self.lines:
            match = re.fullmatch(r"([\w-]+): (.*)", line)
            if match:
                facts[match.group(1)] = match.group(2)
                keys.append(match.group(1))
        object.__setattr__(self, "facts", facts)
        object.__setattr__(self, "keys", keys)

    def has_line(self, pattern: str) -> bool:
        return any(re.search(pattern, line) for line in self.lines)

    def __str__(self) -> str:
        return f"exit code {self.code}:\n" + "\n".join(self.lines)


def make_junction(link: Path, target: Path) -> None:
    """A directory junction, which needs no Developer Mode."""
    link.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == "win32":
        import _winapi

        _winapi.CreateJunction(str(target), str(link))
    else:
        link.symlink_to(target, target_is_directory=True)


def remove_link(link: Path) -> None:
    """Removes a link without touching what it points to."""
    if os.path.isjunction(link):
        link.rmdir()
    elif link.is_symlink():
        try:
            link.unlink()
        except OSError:
            # A symbolic link to a folder, on Windows.
            link.rmdir()


def script_env(sandbox: Sandbox, changes: Mapping[str, str | None] | None = None) -> dict[str, str]:
    """The environment a sandbox's scripts run in. Git stops looking for a repo at the sandbox,
    which is inside this one. CLAUDE_CODE_ENTRYPOINT, which the session running the tests may
    have set, is left out, as are coverage's settings for a run that isn't this Python."""
    env = {key: value for key, value in os.environ.items() if key != "CLAUDE_CODE_ENTRYPOINT"}
    env["GIT_CEILING_DIRECTORIES"] = sandbox.root.as_posix()
    for key, value in (changes or {}).items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    return env


def git(*args: str, cwd: Path | None = None, env: Mapping[str, str] | None = None) -> list[str]:
    """Runs git for building and checking sandboxes, and fails the test when git fails."""
    done = subprocess.run(
        ["git", "-c", "core.autocrlf=false", "-c", "commit.gpgsign=false", *args],
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if done.returncode != 0:
        raise AssertionError(f"git {' '.join(args)} failed: {done.stdout}{done.stderr}")
    return done.stdout.splitlines()


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def new_sandbox(name: str, *, tools_repo: bool = False) -> Sandbox:
    """Builds a sandbox. The copy's local-settings.json, with testHomeDir, is written before
    anything in the copy can run. With tools_repo, the copy is also a git repo with a remote,
    as a clone of dev-home-tools is. The profile's Python install manager folder is a junction
    to this environment's base Python, which setup links the copy's .python to."""
    box = Sandbox(SANDBOX_ROOT / f"py-{name}-{uuid.uuid4().hex[:8]}")
    box.root.mkdir(parents=True)

    def leave_out(folder: str, names: list[str]) -> set[str]:
        top = Path(folder) == REPO_ROOT
        return {
            n
            for n in names
            if n == "__pycache__" or n.startswith(".coverage.") or (top and n in NOT_COPIED)
        }

    shutil.copytree(REPO_ROOT, box.tools, ignore=leave_out)
    settings = {
        "contentDir": box.content.as_posix(),
        "autoUpdate": False,
        "claudeConfigDirs": [],
        "testHomeDir": box.profile.as_posix(),
    }
    write_text(box.tools / "local-settings.json", json.dumps(settings, indent=2) + "\n")

    # A scratch profile whose settings already have what setup checks for, so a clean run
    # exits 0.
    claude = {"permissions": {"additionalDirectories": [str(box.content), str(box.tools)]}}
    write_text(box.profile / ".claude" / "settings.json", json.dumps(claude, indent=2) + "\n")
    write_text(
        box.profile / ".codex" / "config.toml",
        "project_doc_max_bytes = 65536\n\n[sandbox_workspace_write]\n"
        f"writable_roots = ['{box.content}']\n",
    )
    make_junction(box.python_bin, Path(sys.base_prefix))

    # dev-home, with a remote and some content.
    git("init", "--quiet", "--bare", "-b", "main", str(box.remote))
    git("clone", "--quiet", str(box.remote), str(box.content))
    files = {
        "global-rules/global-rules.md": "# My rules\n\n- Personal rule one.\n",
        "knowledge/README.md": "# Knowledge base\n",
        "handoffs/demo/HANDOFF.md": "# demo handoff\n",
        "skills/mine/SKILL.md": "---\nname: mine\ndescription: A personal test skill.\n---\n",
    }
    for relative, text in files.items():
        write_text(box.content / relative, text)
    git("-C", str(box.content), "add", "--", *files)
    git("-C", str(box.content), "commit", "--quiet", "-m", "test: content")
    git("-C", str(box.content), "push", "--quiet", "-u", "origin", "main")

    if tools_repo:
        git("-C", str(box.tools), "init", "--quiet", "-b", "main")
        git("-C", str(box.tools), "add", "-A")
        git("-C", str(box.tools), "commit", "--quiet", "-m", "test: tools")
        git("init", "--quiet", "--bare", "-b", "main", str(box.tools_remote))
        git("-C", str(box.tools), "remote", "add", "origin", str(box.tools_remote))
        git("-C", str(box.tools), "push", "--quiet", "-u", "origin", "main")
    return box


def sandbox_for(
    request: pytest.FixtureRequest, name: str, *, tools_repo: bool = False
) -> Iterator[Sandbox]:
    """A sandbox for a module's tests, after one setup run, which must exit 0. It's deleted
    afterwards when they all pass, and kept for a look when one fails."""
    box = new_sandbox(name, tools_repo=tools_repo)
    failed = request.session.testsfailed
    setup = run_pwsh(box, "setup.ps1", "-Quiet")
    assert setup.code == 0, str(setup)
    yield box
    if request.session.testsfailed > failed:
        print(f"Sandbox kept: {box.root}")
    else:
        remove_sandbox(box)


def remove_sandbox(box: Sandbox) -> None:
    """Deletes a sandbox. Links go first, one by one and without following them, so deleting
    the rest can't reach anything a link points to, such as a Python install."""
    root = box.root.resolve()
    if SANDBOX_ROOT.resolve() not in root.parents:
        raise AssertionError(f"Refusing to delete {root}, which is not in {SANDBOX_ROOT}.")

    def links(folder: Path) -> Iterator[Path]:
        for entry in os.scandir(folder):
            path = Path(entry.path)
            if entry.is_symlink() or os.path.isjunction(path):
                yield path
            elif entry.is_dir():
                yield from links(path)

    for link in list(links(root)):
        remove_link(link)

    def make_writable(function: Callable[..., object], path: str, _error: BaseException) -> None:
        # Git makes its object files read-only.
        Path(path).chmod(stat.S_IWRITE)
        function(path)

    shutil.rmtree(root, onexc=make_writable)
    # Other tests may be running at the same time, and one may have just made its sandbox here.
    with contextlib.suppress(OSError):
        SANDBOX_ROOT.rmdir()


def check_in_sandbox(argv: list[str]) -> None:
    """Refuses to run a script outside a sandbox."""
    for word in argv:
        if word.endswith((".py", ".ps1")):
            path = Path(word).resolve()
            if SANDBOX_ROOT.resolve() not in path.parents:
                raise AssertionError(f"Refusing to run {path}, which is not in a sandbox.")


def run(
    box: Sandbox,
    argv: list[str],
    *,
    cwd: Path,
    env: Mapping[str, str | None] | None = None,
) -> Run:
    """Runs a command as an agent's shell tool does: input from nowhere, so a script can never
    wait for an answer, and its output and errors together, read as UTF-8."""
    check_in_sandbox(argv)
    done = subprocess.run(
        argv,
        cwd=cwd,
        env=script_env(box, env),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return Run(done.returncode, done.stdout.decode("utf-8", errors="replace").splitlines())


def run_pwsh(box: Sandbox, script: str, *args: str, cwd: Path | None = None) -> Run:
    """Runs one of the sandbox copy's PowerShell scripts, such as setup.ps1."""
    pwsh = shutil.which("pwsh") or "pwsh"
    path = str(box.tools / script)
    return run(box, [pwsh, "-NoProfile", "-File", path, *args], cwd=cwd or box.root)


def skill_command(box: Sandbox, skill: str, script: str) -> str:
    """The command a sandbox's generated skill gives for one of the shared scripts, word for
    word. A skill may give the same command more than once, but never two different ones."""
    text = (box.generated / "skills" / skill / "SKILL.md").read_text(encoding="utf-8")
    python = (box.tools / ".python" / "python.exe").as_posix()
    path = (box.generated / "shared-skill-scripts" / script).as_posix()
    pattern = rf"`({re.escape(python)} -I {re.escape(path)}[^`]*)`"
    commands: set[str] = {match.group(1) for match in re.finditer(pattern, text)}
    assert len(commands) == 1, f"{skill} gives {len(commands)} commands for {script}: {commands}"
    return commands.pop()


def run_command(
    box: Sandbox,
    command: str,
    *,
    cwd: Path,
    env: Mapping[str, str | None] | None = None,
    through_link: bool = False,
) -> Run:
    """Runs a skill's command. Its paths have no spaces, so it splits on them. Unless
    through_link, it starts with this environment's Python, by its real path, in place of the
    sandbox's .python/python.exe (see the description above)."""
    words = command.split(" ")
    assert words[0] == (box.tools / ".python" / "python.exe").as_posix(), command
    if not through_link:
        words[0] = sys.executable
    return run(box, words, cwd=cwd, env=env)


def new_repo(
    box: Sandbox, name: str, *, origin: str | None = None, commits: tuple[str, ...] = ("first",)
) -> Path:
    """A project repo in the sandbox, beside its dev-home, with empty commits."""
    repo = box.root / name
    git("init", "--quiet", "-b", "main", str(repo))
    for message in commits:
        git("-C", str(repo), "commit", "--quiet", "--allow-empty", "-m", f"test: {message}")
    if origin is not None:
        git("-C", str(repo), "remote", "add", "origin", origin)
    return repo


# ---------------------------------------------------------------------------------------------
# Reading scripts' code without running it


def call_name(node: ast.Call) -> str:
    """A call's dotted name, such as os.environ.get, or empty text when it has none."""
    parts: list[str] = []
    target: ast.expr = node.func
    while isinstance(target, ast.Attribute):
        parts.append(target.attr)
        target = target.value
    if isinstance(target, ast.Name):
        parts.append(target.id)
        return ".".join(reversed(parts))
    return ""


def main_block_nodes(tree: ast.Module) -> set[ast.AST]:
    """Every node inside the module's if __name__ == "__main__": block."""
    inside: set[ast.AST] = set()
    for statement in tree.body:
        if isinstance(statement, ast.If) and "__name__" in ast.unparse(statement.test):
            for node in statement.body:
                inside.update(ast.walk(node))
    return inside


# What a script that only reports may import: none of these can write files or reach the
# network by being imported, and the calls below are checked one by one.
REPORTING_IMPORTS = {
    "__future__",
    "collections.abc",
    "ctypes",
    "dataclasses",
    "functools",
    "io",
    "os",
    "pathlib",
    "re",
    "shutil",
    "subprocess",
    "sys",
    "typing",
    "urllib.parse",
}
# What it may use of os, shutil, and ctypes, which can also change things.
REPORTING_ATTRIBUTES = {
    "os": {"environ", "path", "pathsep", "sep", "getcwd", "uname", "fspath"},
    "shutil": {"which"},
    "ctypes": {"create_unicode_buffer", "c_ulong", "byref", "WinDLL"},
}
# What it may call from a Windows DLL.
REPORTING_DLL_CALLS = {"GetComputerNameW"}
# Method names that write or remove a file or folder. replace and rename count only with one
# argument, the form pathlib's take: str.replace takes two.
WRITING_METHODS = {
    "write_text",
    "write_bytes",
    "mkdir",
    "touch",
    "unlink",
    "rmdir",
    "chmod",
    "lchmod",
    "symlink_to",
    "hardlink_to",
    "open",
}
ONE_ARGUMENT_WRITERS = {"replace", "rename"}
# What run_git may be given: the first word, or first two, of a git command that only reads.
GIT_READS = {"rev-parse", "rev-list", "cat-file", "remote get-url"}
CHANGING_BUILTINS = {"open", "exec", "eval", "compile", "__import__", "breakpoint"}
ENVIRON_CHANGES = {"update", "pop", "popitem", "setdefault", "clear", "__setitem__", "__delitem__"}


def is_changing_call(node: ast.Call, in_run_git: set[ast.AST]) -> bool:
    """Whether a call may change something or reach the network (see the function below)."""
    name = call_name(node)
    func = node.func
    method = func.attr if isinstance(func, ast.Attribute) else ""
    owner = func.value if isinstance(func, ast.Attribute) else None
    if isinstance(owner, ast.Call) and call_name(owner) == "ctypes.WinDLL":
        # A function from a Windows DLL, such as ctypes.WinDLL("kernel32").Function().
        return method not in REPORTING_DLL_CALLS
    if name.startswith("subprocess."):
        return node not in in_run_git
    if name == "run_git":
        words = [str(a.value) for a in node.args[:2] if isinstance(a, ast.Constant)]
        return not ({words[0] if words else "", " ".join(words)} & GIT_READS)
    if name in CHANGING_BUILTINS or name.startswith("importlib"):
        return True
    if name.startswith("os.environ.") and method in ENVIRON_CHANGES:
        return True
    return method in WRITING_METHODS or (method in ONE_ARGUMENT_WRITERS and len(node.args) == 1)


def find_changes_or_network_use(tree: ast.Module) -> list[ast.AST]:
    """Where a script that should only report changes something or reaches the network, as far
    as its code can show: an import beyond REPORTING_IMPORTS; os, shutil, or ctypes beyond what
    REPORTING_ATTRIBUTES allows; a DLL call beyond REPORTING_DLL_CALLS; a method that writes a
    file; open, exec, and the like; a change to os.environ; or a program started, unless it's
    git run by run_git with a command that only reads."""
    found: list[ast.AST] = []
    in_run_git: set[ast.AST] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "run_git":
            in_run_git.update(ast.walk(node))

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found.extend(node for alias in node.names if alias.name not in REPORTING_IMPORTS)
        elif isinstance(node, ast.ImportFrom):
            if (node.module or "") not in REPORTING_IMPORTS:
                found.append(node)
        elif isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
            allowed = REPORTING_ATTRIBUTES.get(node.value.id)
            if allowed is not None and node.attr not in allowed:
                found.append(node)
        elif isinstance(node, ast.Call) and is_changing_call(node, in_run_git):
            found.append(node)
        elif isinstance(node, (ast.Assign, ast.AugAssign, ast.Delete)):
            targets = node.targets if isinstance(node, (ast.Assign, ast.Delete)) else [node.target]
            for target in targets:
                if isinstance(target, ast.Subscript) and ast.unparse(target.value) == "os.environ":
                    found.append(node)
    return found


# Calls that change what a whole process shares, by their dotted name or its start.
PROCESS_WIDE_CALLS = (
    "os.chdir",
    "os.putenv",
    "os.unsetenv",
    "os.umask",
    "sys.setrecursionlimit",
    "sys.setswitchinterval",
    "locale.setlocale",
    "signal.signal",
    "atexit.register",
    "codecs.register",
)
PROCESS_WIDE_METHODS = {
    "sys.stdout": {"reconfigure"},
    "sys.stderr": {"reconfigure"},
    "sys.stdin": {"reconfigure"},
    "sys.path": {"append", "insert", "extend", "remove", "pop", "clear"},
    "sys.modules": {"pop", "update", "setdefault", "clear", "__setitem__"},
    "os.environ": ENVIRON_CHANGES,
}


def find_process_wide_changes(tree: ast.Module) -> list[ast.AST]:
    """Where a script changes what its whole process shares, outside the block that runs only
    when it's run as a script: environment variables, the current folder, the import path,
    sys's streams, or anything else assigned in sys or os."""
    main_block = main_block_nodes(tree)
    found: list[ast.AST] = []
    for node in ast.walk(tree):
        if node in main_block:
            continue
        if isinstance(node, ast.Call):
            name = call_name(node)
            owner, _, method = name.rpartition(".")
            if name.startswith(PROCESS_WIDE_CALLS) or method in PROCESS_WIDE_METHODS.get(owner, ()):
                found.append(node)
        elif isinstance(node, (ast.Assign, ast.AugAssign, ast.Delete)):
            targets = node.targets if isinstance(node, (ast.Assign, ast.Delete)) else [node.target]
            for target in targets:
                text = ast.unparse(target)
                if text.startswith(("sys.", "os.")):
                    found.append(node)
    return found


def non_standard_imports(tree: ast.Module) -> list[str]:
    """Each module a script imports that isn't part of Python's standard library."""
    names: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            names.append(node.module)
    return [n for n in names if n.split(".")[0] not in sys.stdlib_module_names]
