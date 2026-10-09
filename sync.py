"""Syncs your dev-home with GitHub, commits only the files it's given, and checks dev-home-tools
for updates. Run it with Python 3.12 or later, such as:

    py C:/Users/you/dev-home-tools/sync.py

--help says what it does, and how to commit with it. The code is in internal/shared/sync.py, and
this file only loads it; internal/shared/__init__.py says why.
"""

import importlib
import importlib.util
import io
import sys
from pathlib import Path
from types import ModuleType

# An older Python can still read this far, so it gets a message instead of a syntax error.
if sys.version_info < (3, 12):  # noqa: UP036
    sys.exit("dev-home-tools needs Python 3.12 or later, and this is " + sys.version.split()[0])


def load(name: str) -> ModuleType:
    """Loads a module of internal/shared/ by its path: python -I leaves this folder off the
    import path."""
    folder = Path(__file__).parent / "internal" / "shared"
    spec = importlib.util.spec_from_file_location(
        "dev_home_tools_shared", folder / "__init__.py", submodule_search_locations=[str(folder)]
    )
    if spec is None or spec.loader is None:
        raise ImportError(str(folder) + " could not be loaded")
    package = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = package
    spec.loader.exec_module(package)
    return importlib.import_module(spec.name + "." + name)


def stopped(error: Exception) -> str:
    """A PROBLEM line for code that couldn't load or run, with the way to install a fix by hand,
    since a sync that can't run can't install one either."""
    tools = Path(__file__).parent.as_posix()
    launcher = "py" if sys.platform == "win32" else "python3"
    return (
        f"PROBLEM   {Path(__file__).name} stopped: {type(error).__name__}: {error}. If an update"
        f" has a fix, install it by hand: git -C {tools} pull --ff-only, then"
        f" {launcher} {tools}/setup.py"
    )


if __name__ == "__main__":
    # Agents read UTF-8, but Python writes the console's code page when its output is redirected.
    for stream in (sys.stdout, sys.stderr):
        if isinstance(stream, io.TextIOWrapper):
            stream.reconfigure(encoding="utf-8")
    try:
        code = load("sync").main(sys.argv[1:])
    except Exception as error:
        print(stopped(error))
        code = 1
    except KeyboardInterrupt:
        # Ctrl+C isn't an Exception. It's caught here, not in main, so it also stops the update
        # check's and setup's code when they run inside this process.
        # 130 is what shells report for a program Ctrl+C stopped.
        print(f"\n{Path(__file__).name} stopped: Ctrl+C was pressed.")
        code = 130
    sys.exit(code)
