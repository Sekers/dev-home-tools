"""The code behind dev-home-tools' scripts, loaded by the entry points in the root and by
prepare.py.

sync.py and update.py in the root are short entry points that load this package and run its
module of the same name. prepare.py, which every skill command that syncs starts with, loads it
too, and runs sync inside its own process. setup.ps1 is still PowerShell, and loads git.ps1 and
output.ps1 from this folder instead.

Each entry point loads this package by its path, as dev_home_tools_shared, because python -I
leaves the script's folder off the import path. The code isn't in the root files themselves
because Python writes a __pycache__ folder beside any file another script loads, and the root
holds only what must be there.

Everything here runs inside prepare.py's process, so nothing may change what the whole process
shares, such as environment variables, the current folder, or sys's streams, and a test reads
each file for that. Python 3.12 or later, the standard library only, and ASCII only (tests check
both). One file per job, named for it.
"""
