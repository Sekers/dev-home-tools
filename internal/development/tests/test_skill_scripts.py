"""templates/shared-skill-scripts/ and the skills that run them, read without running anything."""

import ast
import re
from collections.abc import Callable
from pathlib import Path

import pytest

from helpers import (
    REPO_ROOT,
    find_changes_or_network_use,
    find_process_wide_changes,
    non_standard_imports,
)

SCRIPTS = REPO_ROOT / "templates" / "shared-skill-scripts"
SKILLS = REPO_ROOT / "templates" / "skills"


def scripts() -> list[Path]:
    return sorted(SCRIPTS.glob("*.py"))


def skills() -> list[Path]:
    """Each skill, as setup sees one: a folder with a SKILL.md."""
    return sorted(folder for folder in SKILLS.iterdir() if (folder / "SKILL.md").is_file())


def parse(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def lines_of(nodes: list[ast.AST], source: Path) -> list[str]:
    text = source.read_text(encoding="utf-8").splitlines()
    numbers = [getattr(node, "lineno", 0) for node in nodes]
    return [f"{source.name}:{n}: {text[n - 1].strip()}" for n in numbers]


@pytest.mark.parametrize("script", scripts(), ids=lambda p: p.name)
def test_each_script_lists_exactly_the_skills_that_run_it(script: Path) -> None:
    # So whoever changes the script knows what depends on it. A skill runs it when any of the
    # skill's files holds its path.
    match = re.search(r"^Called by: (.+)$", script.read_text(encoding="utf-8"), re.MULTILINE)
    listed = sorted(re.split(r",\s*", match.group(1).strip())) if match else []
    needle = "{{SHARED_SKILL_SCRIPTS_DIR}}/" + script.name
    callers = sorted(
        skill.name
        for skill in skills()
        if any(needle in f.read_text(encoding="utf-8") for f in skill.rglob("*") if f.is_file())
    )
    assert listed == callers, f'"Called by: {", ".join(listed)}", but run by: {callers}'


@pytest.mark.parametrize("skill", skills(), ids=lambda p: p.name)
def test_each_shared_script_command_is_stamped_and_pre_approved_word_for_word(
    skill: Path,
) -> None:
    # A command that differs from its pre-approval by one word would ask the user first. Each
    # carries the skill's own name and stamp, which the scripts check against the skill on disk.
    text = (skill / "SKILL.md").read_text(encoding="utf-8")
    allowed = re.search(r'^allowed-tools:\s*"(.*)"\s*$', text, re.MULTILINE)
    approvals = allowed.group(1) if allowed else ""
    prefix = "{{PYTHON}} -I {{SHARED_SKILL_SCRIPTS_DIR}}/"
    commands = set(re.findall(rf"`({re.escape(prefix)}[^`]*)`", text))
    assert commands, f"{skill.name} runs no shared script"
    for command in commands:
        script = command[len(prefix) :].split(" ")[0]
        assert (SCRIPTS / script).is_file(), f"{skill.name} runs {script}, which doesn't exist"
        assert f" --skill {skill.name} --stamp {{{{SKILL_STAMP}}}}" in command, command
        assert f"Bash({command})" in approvals, f"not pre-approved for Bash: {command}"
        assert f"PowerShell({command})" in approvals, f"not pre-approved for PowerShell: {command}"


# Samples for the searches below: each line in a "found" list must be found, and nothing in a
# "not found" list.
CHANGES = [
    "import socket",
    "from urllib.request import urlopen",
    "import tempfile",
    "os.remove('x')",
    "os.system('git fetch')",
    "shutil.rmtree('x')",
    "Path('x').write_text('y')",
    "Path('x').replace('y')",
    "open('x', 'w')",
    "subprocess.run(['git', 'fetch'])",
    "run_git('fetch', 'origin')",
    "run_git('remote', 'add', 'x', 'y')",
    "os.environ['X'] = '1'",
    "os.environ.update(X='1')",
    "ctypes.windll.kernel32.DeleteFileW('x')",
    "ctypes.WinDLL('kernel32').DeleteFileW('x')",
    "exec('x')",
    "importlib.import_module('socket')",
]
READS = [
    "import os, re, subprocess",
    "from urllib.parse import quote",
    "os.environ.get('X')",
    "os.path.abspath('x')",
    "shutil.which('git')",
    "Path('x').read_text()",
    "'a\\r\\n'.replace('\\r\\n', '\\n')",
    "run_git('rev-parse', 'HEAD')",
    "run_git('remote', 'get-url', 'origin')",
    "run_git('cat-file', '--batch-check')",
    "ctypes.WinDLL('kernel32').GetComputerNameW(b, s)",
    "def run_git(*args):\n    return subprocess.run(['git', *args])",
]
PROCESS_WIDE = [
    "os.environ['X'] = '1'",
    "os.chdir('x')",
    "sys.path.insert(0, 'x')",
    "sys.stdout.reconfigure(encoding='utf-8')",
    "sys.modules['x'] = None",
    "sys.stdout = None",
]
PROCESS_READS = [
    "x = os.environ.get('X')",
    "print(sys.path)",
    "if __name__ == '__main__':\n    sys.stdout.reconfigure(encoding='utf-8')",
]


def found_lines(search: Callable[[ast.Module], list[ast.AST]], samples: list[str]) -> list[str]:
    return [s for s in samples if search(ast.parse(s))]


def test_the_search_for_changes_and_network_use_finds_each_kind_and_no_reads() -> None:
    assert found_lines(find_changes_or_network_use, CHANGES) == CHANGES
    assert found_lines(find_changes_or_network_use, READS) == []


def test_the_search_for_process_wide_changes_finds_each_kind_and_no_reads() -> None:
    assert found_lines(find_process_wide_changes, PROCESS_WIDE) == PROCESS_WIDE
    assert found_lines(find_process_wide_changes, PROCESS_READS) == []


def test_facts_changes_nothing_and_never_uses_the_network() -> None:
    # Which is what lets a skill run it without asking first.
    facts = SCRIPTS / "facts.py"
    assert lines_of(find_changes_or_network_use(parse(facts)), facts) == []


def test_facts_changes_nothing_the_whole_process_shares() -> None:
    # prepare.py runs it inside its own process.
    facts = SCRIPTS / "facts.py"
    assert lines_of(find_process_wide_changes(parse(facts)), facts) == []


@pytest.mark.parametrize("script", scripts(), ids=lambda p: p.name)
def test_each_script_uses_only_the_standard_library(script: Path) -> None:
    # People install only Python, and the test tools are importable when the tests run them.
    assert non_standard_imports(parse(script)) == []


@pytest.mark.parametrize("script", scripts(), ids=lambda p: p.name)
def test_each_script_is_ascii(script: Path) -> None:
    text = script.read_bytes()
    assert text.isascii(), [n for n, line in enumerate(text.splitlines(), 1) if not line.isascii()]
