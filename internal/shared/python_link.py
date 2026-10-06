"""Finding a Python 3.12 or later for the skills' scripts, which setup links internal/.python to."""

import re
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path

if sys.platform == "win32":
    import winreg

MINIMUM = (3, 12)
# Where each Windows hive keeps the runtimes it knows (PEP 514).
REGISTRY_ROOTS = (r"Software\Python", r"Software\WOW6432Node\Python")


def parse_version(text: object) -> tuple[int, ...] | None:
    if not isinstance(text, str) or not re.fullmatch(r"\d+(\.\d+){1,3}", text.strip()):
        return None
    return tuple(int(part) for part in text.strip().split("."))


def subkeys(key: "winreg.HKEYType") -> list[str]:
    names: list[str] = []
    index = 0
    while True:
        try:
            names.append(winreg.EnumKey(key, index))
        except OSError:
            return names
        index += 1


def value(key: "winreg.HKEYType", name: str) -> str:
    try:
        found = winreg.QueryValueEx(key, name)[0]
    except OSError:
        return ""
    return found if isinstance(found, str) else ""


def registered_python(
    company_key: "winreg.HKEYType", tag: str
) -> tuple[tuple[int, ...], Path] | None:
    """One runtime's version and folder, from its key under a company, or None when it's older
    than 3.12, can't be read, or can't be run from its folder."""
    try:
        with winreg.OpenKey(company_key, tag) as tag_key:
            version = parse_version(value(tag_key, "SysVersion"))
            if version is None or version < MINIMUM:
                return None
            with winreg.OpenKey(tag_key, "InstallPath") as install:
                exe = value(install, "ExecutablePath")
                if not exe:
                    exe = str(Path(value(install, "")) / "python.exe")
    except OSError:
        return None
    # A Microsoft Store Python runs only through its own alias, never from its folder.
    if not re.search(r"[\\/]python\.exe$", exe, re.IGNORECASE):
        return None
    if re.search(r"[\\/]WindowsApps[\\/]", exe, re.IGNORECASE):
        return None
    return version, Path(exe).parent


def registry_pythons() -> list[Path]:
    """The folders of the runtimes in the registry, newest first, which covers the traditional
    installer."""
    if sys.platform != "win32":
        return []
    found: list[tuple[tuple[int, ...], Path]] = []
    roots = [(winreg.HKEY_CURRENT_USER, REGISTRY_ROOTS[0])]
    roots += [(winreg.HKEY_LOCAL_MACHINE, root) for root in REGISTRY_ROOTS]
    for hive, root_path in roots:
        try:
            root = winreg.OpenKey(hive, root_path)
        except OSError:
            continue
        with root:
            for company in subkeys(root):
                # PyLauncher registers the py launcher, not a Python.
                if company == "PyLauncher":
                    continue
                try:
                    with winreg.OpenKey(root, company) as company_key:
                        for tag in subkeys(company_key):
                            runtime = registered_python(company_key, tag)
                            if runtime is not None:
                                found.append(runtime)
                except OSError:
                    # A key this user can't open is skipped, as any other runtime that can't be
                    # used.
                    continue
    found.sort(key=lambda pair: pair[0], reverse=True)
    folders: list[Path] = []
    for _, folder in found:
        if folder not in folders:
            folders.append(folder)
    return folders


def candidates(local_app_data: Path, *, skip_registry: bool) -> Iterator[Path]:
    """Folders that may hold a Python 3.12 or later as python.exe, best first. First the Python
    install manager's shortcut folder, whose python.exe runs the default runtime and follows it
    to newer ones. Then the runtimes in the registry, read only when the first won't do. With
    skip_registry, as for a test profile, only the first, since tests can't add registry
    entries."""
    yield local_app_data / "Python" / "bin"
    if not skip_registry:
        yield from registry_pythons()


def is_new_enough(folder: Path) -> bool:
    """Whether the python.exe in a folder runs and is 3.12 or later. This starts Python, so setup
    asks only when it makes the link, or re-points it."""
    exe = folder / "python.exe"
    if not exe.is_file():
        return False
    try:
        done = subprocess.run(
            [str(exe), "-I", "-c", "import sys; print(sys.version_info >= (3, 12))"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    lines = done.stdout.split()
    return done.returncode == 0 and bool(lines) and lines[-1] == "True"
