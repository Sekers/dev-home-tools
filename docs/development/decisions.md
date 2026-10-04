# Design decisions

Decisions about how dev-home-tools works, and options that were looked at and set aside. Each
entry gives the decision, the reason, and what would be a reason to look again. Read the entry
before reopening a question, and change it when the answer changes.

## The skills are not shipped as plugins

**Decision:** not for now. Setup keeps filling in the skills and rules for each PC and linking
them into Claude Code and Codex.

**The option:** ship the skills, and perhaps hooks, as Claude Code and Codex plugins. That could
bring each tool's own install and updates, no junctions or Windows-only steps, and hooks that
enforce a rule instead of asking agents to follow it, such as blocking an edit under
`internal/.generated/`.

**Why not:** Codex would gain nothing, and Claude Code would gain little that setup can't
already do. Checked on 2026-09-30 against both tools' plugin docs, and with a test plugin in
Claude Code 2.1.284. Claude Code's mods docs were read on 2026-10-03, for 2.1.287:

- **Claude Code.** `${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_SKILL_DIR}` are filled in inside
  `Bash(...)` pre-approvals (tested). The dev-home path could be a `userConfig` option, but that
  is filled in only in the skill's text. `sync.ps1` has to run from the clone, so the plugin
  would have to load in place, from the clone added as a local-directory marketplace; a plugin
  installed from GitHub is copied into a versioned cache. Commands become
  `/dev-home-tools:handoff`, though a bare `/handoff` still works while nothing else uses the
  name (tested).
- **Codex.** Its docs say "Plugins aren't available in the IDE extension." It copies even a
  local plugin into `~/.codex/plugins/cache/` and loads the copy, so each change needs a
  reinstall and a restart, and its docs name no path substitution in `SKILL.md`. Setup would
  still have to fill in and link the skills for Codex.
- **Always-on rules.** Codex doesn't load instruction files from a plugin, and Claude Code
  ignores a plugin's `CLAUDE.md`. Since Claude Code 2.1.287, though, a mod (a plugin with code
  that runs inside Claude Code) can add instruction files through its `prompt.context` event, as
  the built-in `agents-md` mod does for `AGENTS.md`. Its docs name no size limit. Whether a mod
  can add files that apply in every project, as these rules do, is untested. Either way, a mod
  would only match what the links setup makes already do at no cost, and it would bring
  downsides:
  - `--safe-mode` and `"disableAllHooks": true` turn installed mods off.
  - Mods don't run in the Desktop app's WSL sessions.
  - A mod runs with full access and no consent prompt.

  Without a mod, only a SessionStart hook could print the rules: capped at 10,000 characters in
  Claude Code and about 2,500 tokens by default in Codex, which also asks the user to trust the
  hook again after every change.
- **What setup would still do.** Nearly everything, plus registering the plugin in each Claude
  config folder, and `update.ps1` would still pull the clone. Hooks don't need a plugin: setup
  could add them to `settings.json`, with the same consent as its other settings changes.

**Look again if:** Codex plugins work in its IDE extension and can load in place, or hooks
become worth having.

## No safety net for hand edits to generated files

**Decision:** none for now, beyond the note at the top of each generated file.

**The problem:** setup rewrites `internal/.generated/` (and Codex's `AGENTS.md`) on every run
without checking for edits, so an edit made there is lost at the next sync, with no message.
Each skill's `SKILL.md` and the operating rules open with a note naming the template to change
instead, which agents see when the skill or rules load, and people see when they open the file.
That leaves the generated files with no note (`facts.py`, `prepare.py`, `filing-rules.md`, and
the handoff `template.md`, which can't have one because it's copied into every new handoff), and
anyone who ignores the note.

**Options set aside:** record what setup last wrote and, when a file differs, keep a copy and
report a `PROBLEM` (as chezmoi does); keep a `.bak` of the old file (as Ruler does); or make the
generated files read-only.

**Look again if:** an edit is ever actually lost, or plugins are looked at again (see above),
where a hook could block agents' edits under `internal/.generated/`.

## Scripts the skills share are generated once, and skills point to them

**Decision:** a script that more than one skill may run, and that only agents run, lives in
`templates/shared-skill-scripts/`. Setup generates one copy into
`internal/.generated/shared-skill-scripts/`, and every skill runs that copy. The first was
`facts.py`, which reports facts about where a session is running, one topic at a time.

**Why not a copy in each skill's folder:** most published skills are built that way, so that a
skill can be installed alone. These skills come with the toolkit, so that buys little here. One
path gives each command one text to pre-approve, where copies would give the same command a
different path in every skill, and a turned-off skill leaves nothing behind.

**Why not the root:** the root holds what a person may run by hand. A script there looks like
one of those.

**Why not inside `templates/skills/`:** setup and the tests treat every folder there as a skill:
setup generates and links only the ones with a `SKILL.md`, and removes any other folder from
`internal/.generated/skills/`, and the docs test wants a page in `docs/skills/` for each. A
shared folder there would need an exception in each of those.

**Why not `internal/`, or a folder of its own, run in place:** a half-finished edit to a script
that runs in place is live at once in every session on the PC. A generated script changes only
when setup runs, in the same run that rewrites the skill text that calls it, so the two files
are never out of step. A session that loaded the skill before that run still has the old text
until the user runs the skill's command again, and the skill's stamp tells it so (see below).
`templates/` is also where everything the tools get from this repo already lives.

**Why one script with topics, not one that does everything:** `facts.py` is safe to pre-approve
because it only reports, and only from this PC. A script that also changed things would lose
that, so anything a skill needs done goes in a script of its own.

**Look again if:** the skills are shipped without the toolkit, as a plugin for example (see
above), where each would need the scripts bundled with it.

## The skills don't say to run each command in its own call

**Decision:** no such rule.

**The problem:** agents joined the commands a skill gave them, such as `sync.ps1; facts.ps1`,
although the skill said to run them exactly as written. A joined call asks the user first when
any part of it isn't pre-approved.

**Why not:** a joined call whose parts are all pre-approved runs without asking (seen in Claude
Code 2.1.286), so joining isn't what causes a prompt: an unapproved part is. The fix for that is
a pre-approved way to get what the agent wanted, which is how the facts came to include the
computer's name. Running two commands in one call also saves a round trip. Since then, every
skill command that syncs starts with one script anyway (see the next entry).

**Look again if:** a tool starts asking about joined commands whose parts are all pre-approved.

## Every skill command that syncs starts with one call: prepare.py

**Decision:** `templates/shared-skill-scripts/prepare.py` runs `sync.ps1`, then loads `facts.py`
into its own process, checks the skill's stamp, and prints the facts for the topics a skill
names. It's the first command of every skill command that syncs. Skills still commit through
`sync.ps1 -Message`.

**The problem:** each command an agent runs costs a turn of the model, and turns cost more time
than the scripts do. A plain `/handoff` took five: `facts.ps1`, `sync.ps1`, reading the handoff,
a `git log` that agents added on their own to see what changed since the handoff's last check,
and the summary. Now it takes three.

**Why one script:** it's one literal command, with one pre-approval, that an agent can't split,
reorder, or send as two calls at once, and it works the same in every tool and on every
platform. The order matters: setup, which the sync runs, rewrites the generated `facts.py` when
its template has changed, so the facts come from the new copy, never from one being written. It
always exits 0, because a failing exit code makes a tool report the whole call as failed, and an
agent could then stop instead of following the skill's steps for each line.

**Why shared:** every skill command that syncs starts the same way, so this is the one place for
what would otherwise be copied into each skill, such as handling a tool that can't sync.

**Options set aside:**

- Each skill joining `sync.ps1; facts.ps1` in one line: it rests on each tool approving joined
  commands, and gives other skills nothing to build on.
- A switch on `sync.ps1` that also prints the facts: `sync.ps1` is for people too, while this is
  only for agents.
- Printing the handoff from the script as well, to save reading it: a long handoff passes the
  30,000 characters Claude Code shows of a command's output, and editing a file needs a real read
  of it anyway.

**Look again if:** a skill needs something at its start that one call can't give it.

## The skills don't run commands as they load

**Decision:** no skill uses Claude Code's `` !`command` `` lines, which run a command as the
skill loads and put its output in the skill's text.

**The option:** run `prepare.py` that way, saving one more turn per skill command in Claude Code.
Codex would get the line as text, and run the command itself.

**Why not:** when the command can't run cleanly, the whole skill aborts before the model sees
it, with a raw error and nothing to explain it. Tested on 2026-10-02 with Claude Code 2.1.284,
through `claude -p` and probe skills:

- It runs for a typed command and when the model starts the skill, again at each use, in the
  session's folder, and the model sees the output.
- A command that exits non-zero, or one no rule allows, aborts the skill.
- With the PowerShell tool on, as it is by default on Windows with a claude.ai account, a Claude
  Code that can't find Git Bash runs the command through the PowerShell tool, which refuses one
  that starts `pwsh`, and the skill aborts. That happened with `claude` started from a Git Bash
  terminal. With `shell: bash` in the frontmatter it aborts too, saying Git Bash wasn't found.
- A slow command holds the skill back until it finishes, and Claude Code's docs give it 2
  minutes.

Without it, each of those cases still works, with a prompt or a slow call. Knowledge lookups
couldn't use it either, since they never sync.

**Look again if:** Claude Code passes a failed command's output to the model instead of
aborting, or finds Git Bash however it was started. Since `prepare.py` always exits 0, each
skill would need only the one line.

## facts.py finds the commit the handoff's State line names

**Decision:** the `newer-commits` topic of `facts.py` finds the commit hashes in the handoff's
State line that the project has, takes the one with the fewest commits after it, which is the
latest the update knew of, and counts both ways: `newer`, the commits this checkout has that it
doesn't, and `behind`, the ones it has that this checkout doesn't. The handoff skill's read
mentions newer commits, and says to pull when the checkout is behind. That's the common case
across PCs: work pushed from one, and not pulled yet on the other. A backticked hash this
checkout doesn't have at all gives `checked: missing`, with the same advice, since a commit the
update knew of is absent. Only a hash with letters and digits counts there, so a plain number or
a word such as `deadbee` doesn't raise it. One `git cat-file --batch-check` looks up every hash
at once, and one `git rev-list --left-right --count` gives both counts.

It looks for hashes only: a tag or branch name, such as `main`, would be too easy to match by
accident. A count it can't tell is `unknown`, never `none` or `0`, which would read as "nothing
changed". A git failure never stops the script, because the topics that say where the handoff
is matter more.

**The problem:** agents checked this on their own, with a `git log` from the State line's
commit: one more turn, and only in some sessions.

**Why in the script:** the same answer in every session, with no extra turn, from a command the
skill runs anyway.

**Options set aside:**

- A topic printing only the project's current commit, for the agent to compare: a `git log`
  turn would still follow whenever the project had moved on.
- Leaving it to agents, as before.

**Look again if:** the State line gets a fixed form for the commit, or the handoff template
stops starting with it.

## dev-home-tools moves from PowerShell to Python, in phases

**Decision:** the scripts move to Python 3.12 or later, in three phases: 1. the scripts the
skills share, `facts.py` and `prepare.py`, with `prepare.py` still running `sync.ps1`; 2.
`sync.ps1` and `update.ps1`, loaded into `prepare.py`'s process; 3. `setup.ps1`, and then
PowerShell is no longer needed. No phase may add script time: measure each one against the
flow before it, and ask before anything adds time (AGENTS.md's "Speed").

**The problem:** starting PowerShell is slow, and a `/handoff` started four PowerShell
processes: about 2.6 s on one laptop, where Python started from its full path took about
0.11 s. There, the Python facts took 0.63 s against 1.6 s for `facts.ps1`, and the flow as a
whole took about 7.8 s of script time (the sync 6.6 s, `facts.ps1` 1.2 s). On a faster PC, the
first phase's start of a `/handoff` (`prepare.py` with three topics) took 1.2 s, against 1.4 s
for `sync.ps1` and `facts.ps1` before it, in one call instead of two. PowerShell also writes and
reads in the console's code page, so an accented letter in a path or commit subject reached the
agent garbled, and fixing that took about 30 lines; Python takes one setting. And Python 3 comes
with nearly every macOS and Linux system, where PowerShell is a rare extra install.

**Python is required, never bundled:** a copy in the repo would need its own security updates,
a build for each platform, and room in every clone's history. On Windows, people install it
with the Python install manager, since the traditional installer stops with Python 3.16. The
floor is 3.12, which the tests need too (`os.path.isjunction`, and `shutil.rmtree`'s `onexc`).

**Phase 3 must keep setup from ever waiting for input nobody can give,** as `setup.ps1` never
does. In Python, `sys.stdin.isatty()` is the wrong check on Windows: it's true for the `NUL`
input that agents' commands get. So: `-Quiet` never asks; it asks only when input is a real
console (`GetConsoleMode` on Windows, `isatty()` elsewhere); `EOFError` counts as no; and the
tests run setup with input from `NUL` and from an open, silent pipe.

**Look again if:** a phase can't be done without adding time.

## The skills run Python through a junction, internal/.python

**Decision:** every skill command starts with `{{PYTHON}} -I`, and setup fills in `{{PYTHON}}`
as `internal/.python/python.exe` in dev-home-tools' folder. `internal/.python/` is a directory
junction setup makes to the Python install manager's shortcut folder,
`%LocalAppData%\Python\bin`, or else to the folder of the newest Python 3.12 or later in the
registry (PEP 514), which covers the traditional installer. Each run checks only that the
junction's `python.exe` is there, which starts no process. Setup starts Python to check its
version only when it makes the junction, or re-points it because that `python.exe` is gone. A
symbolic link will do the same job on macOS and Linux.

**Why a junction:** dev-home-tools' path has no spaces, so the command is the same unquoted text
in Claude Code's Bash and PowerShell tools and in Codex, and each is pre-approved as both
`Bash(...)` and `PowerShell(...)`. Python's own path is usually under the user's profile, which
can have a space, and a quoted path needs a different text in each tool (a probe skill showed
both tools pre-approving a Python command). Python runs normally through a junction, which added
3 to 5 ms to a start of about 32 ms.

**Why the install manager's shortcuts first:** each runs the default runtime and moves on to newer
ones as they're installed, with no work for setup. They ignore a virtual environment and a
script's request for a version, so a project's environment can't change which Python runs.

**Why `internal/`:** it's machinery nobody runs directly, which is what `internal/` is for, and
the root is kept to what must be there (see "What the root holds"). It isn't generated content,
so not `internal/.generated/`; and sync's and setup's agent commands will run through it too in
phases 2 and 3, so not `shared-skill-scripts/`. The dot keeps it apart from Python code that
phase 2 may put in `internal/`. Setup's cleanup of the generated files never looks inside a link,
so a junction nearby can't lead it into the Python install.

**Why `-I`:** it ignores `PYTHON*` environment variables and the user's site-packages, so nothing
in a project's environment can change what loads. It costs no measurable time. It also leaves the
script's folder off the import path, so `prepare.py` loads `facts.py` by its path.

**The bytecode cache stays:** Python writes `__pycache__` beside the scripts, and setup leaves it
alone. Without it, compiling a 600-line module took about 8 ms on every run.

**Options set aside:**

- A `.cmd` launcher: it added about 38 ms, and cmd.exe parses arguments again, which isn't safe
  for phase 2's commit messages.
- `python` from the PATH: on Windows it goes through the Microsoft Store alias, which took about
  0.42 s to start.
- Pointing a test sandbox's Python link at the test environment's Python: a virtual
  environment's `python.exe` can't run through a junction ("failed to locate pyvenv.cfg",
  tested with uv's virtual environment and Python 3.14). The tests start the skills' commands
  with that environment's Python by its real path instead, and one test runs a command through
  the link.
- One root folder for everything that belongs to the PC (the settings, the generated files, and
  the link): a bigger change, for files that had no need to move.

**Not tested yet:** the install manager's shortcut after its runtime is uninstalled
(`py install --refresh` repairs it); a junction on a Dev Drive, which is ReFS and documented as
supporting junctions; and symbolic links on macOS and Linux.

**Look again if:** setup goes beyond Windows, or a Python the scripts need can't be reached
through a junction.

## Folders for what several skills share

**Decision:** one skill's files live in its own folder under `templates/skills/`, and what
several skills share lives in a `templates/shared-skill-*` folder for its kind:
`templates/shared-skill-scripts/` for scripts, which setup fills in and installs, and
`templates/shared-skill-text/` for instruction text several skills need word for word, which
setup will paste into each `SKILL.md` and never install, once that's built.

**Why sibling folders, not one folder with `scripts/` and `text/` inside:** setup installs the
scripts but only reads the text, so each folder keeps one job, with no extra layer and shorter
command paths. "shared" is in both names because `skill-scripts` read as every skill's scripts,
and "skill" keeps them apart from `internal/shared/`, which only the scripts at the root load.

**Look again if:** a third kind of shared file comes along that doesn't fit either.

## A stamp tells a session that its skill has changed

**Decision:** setup stamps each skill with a fingerprint of its `SKILL.md`: the start of a SHA-256
of the text with this PC's paths filled in, written into the skill's own commands as
`--skill <name> --stamp <stamp>`. `prepare.py` and `facts.py` compare the stamp they're given
with the one in that `SKILL.md` on disk. When they differ, `prepare.py` prints a `RELOAD` line,
and `facts.py` an error, saying the session's steps are out of date and to ask the user to run
the skill's command again. Neither prints any facts then, so the old steps can't carry on.

**The problem:** an agent keeps the text of a skill it has loaded. When an update changes the
skill partway through a session, the agent follows the old steps, which may run scripts that
have changed or are gone.

**Why the stamp:** every skill command that changes anything starts with `prepare.py`, after the
sync that may install the change, so this catches any change to a skill, not just renamed
scripts. It adds a file read and a comparison, and no process. Typing a skill's command again
loads its new text and its new pre-approvals, with no need for a new session (tested); an agent
that invokes the skill again itself is asked first outside auto mode, so the skill asks the user
instead.

**Look again if:** the tools reload a skill by themselves when its file changes.

## No backwards compatibility in the scripts, for now

**Decision:** the scripts carry no code for older versions of dev-home-tools: nothing that moves
an older layout forward, keeps an old path working, or forwards an old script to a new one. When
a change needs something done on each PC that's already set up, such as deleting a folder the
old layout used, it's done there by hand, and the change says what.

**Why:** only the user's own two PCs run dev-home-tools today, so a step by hand on each is
cheaper than code that stays in the scripts long after both have moved. And dev-home-tools has
no changelog or version numbers yet, so there's nothing to say which versions such code would
have to cover.

**What it means for the move to Python:** a session that loaded a skill before an update can
find its old steps naming paths that are gone. Its steps say to show the error and stop, and
typing the command again loads the new ones; the skill's stamp catches the rest (see above).
In phases 2 and 3, `sync.ps1`, `update.ps1`, and `setup.ps1` don't forward to the Python
versions: the operating rules and the docs change with them, and each PC is updated by hand.

**Options set aside:**

- Setup moving an older layout forward, such as removing the root's `.generated/` from before
  the generated files moved into `internal/`, and re-pointing the links into it.
- A stand-in at an old script's path, printing that the skill changed.
- Forwarders from the PowerShell scripts to their Python versions through phases 2 and 3.

**Look again if:** dev-home-tools gets a changelog and version numbers, or people other than its
author use it.

## The tests run on pytest

**Decision:** pytest is the one entry point for the tests. `internal/development/pyproject.toml`
holds the 3.12 floor, a development group (`pytest`, `pytest-xdist`, `pytest-cov`, `ruff`,
`mypy`), and each tool's settings, and `uv.lock` beside it pins them (see "What the root holds"
for why there). `mypy` runs in strict mode and `ruff` checks and formats from the first Python
file. The tests in `internal/development/tests/` share `helpers.py`, and until phase 3
`test_powershell.py` runs `Invoke-Tests.ps1` one group at a time for the scripts not moved yet.
Fakes only stand in for what needs a person or an outside service; git and the file system stay
real. Coverage is a report run on demand, with no minimum. A test checks that the scripts use
only the standard library, since the test tools are importable when the tests run them.

**Why:** fixtures share one sandbox among a module's tests, `pytest-xdist` runs the groups in
parallel (the whole suite, PowerShell groups included, in about 30 s), and the "needs a person"
paths can get tests once they're Python, with small fakes for the person.

**Options set aside:**

- A plain script, as `Invoke-Tests.ps1` is: every runner feature would be written by hand.
- Pester: the scripts are moving to Python. An earlier version of this entry counted Pester's
  install against it, but an install isn't a reason against a development tool.
- `unittest`: no fixtures to share a sandbox, and no parallel runs.
- `pyright`: its PyPI package needs Node.
- `ty`: still in beta (0.0.84 when looked at). Look again once it's stable.
- A coverage minimum: the number would steer what gets tested.

**Look again if:** CI is added, or the suite gets slow.

## What the root holds

**Decision:** the root holds only what must be there, and the scripts a person runs by hand.
AGENTS.md lists them, with the rule to ask before adding anything there. The rest of what used to
be there lives under `internal/`: the generated files in `internal/.generated/`, the Python link
in `internal/.python/`, and everything for development in `internal/development/` (the tools'
settings, the tests, and what the tools write: `.venv`, caches, and the test sandboxes).

**Why each item stays:**

- `.gitattributes` and `.gitignore`: git applies them to the whole repo only from the root.
- `AGENTS.md` and `CLAUDE.md`: Codex and Claude Code read them from the root.
- `LICENSE`: GitHub's docs put it in the root.
- `README.md`: GitHub's front page, and where people look first. GitHub would also show one from
  `docs/` or `.github/`, so this one is convention.
- `setup.ps1`, `sync.ps1`, and `update.ps1`: people run them by hand. They stay the real scripts,
  with no shortcuts: after phase 3 they run as `py <path>\setup.py`, since the Python install
  manager's `py` is an app execution alias in `%LocalAppData%\Microsoft\WindowsApps`, which
  Windows puts on every user's PATH by default (aliases arrived in Windows 10 version 1709), and
  as `python3` on macOS and Linux.
- `templates/`: the repo's main content, what setup fills in and links into the tools.
- `internal/`: there to keep everything else out of the root.
- `docs/`: GitHub Pages, without a build workflow, publishes only from the root or `docs/`.
- `local-settings.json`: people edit it by hand to change a setting.

**Why `.generated/` moved, though every PC's links pointed into it:** that was only a reason
about the cost of moving, and on its merits the folder is machinery nobody runs or edits. It
moved in the same update as phase 1's other changes to it, so each PC goes through one
transition. On a PC set up before, the old folder is deleted by hand; setup then replaces the
links into it, as it does any link whose target is gone.

**Why `internal/development/`, with the tests in it:** ruff finds its settings by looking in a
file's folder and the ones above it, so tests under the settings get them with no flag, in the
editor too. "development" matches `docs/development/`; `dev/` or `dev-tools/` would read like
"dev-home" or "dev-home-tools".

**What it costs:** longer development commands (`uv run --directory internal/development ...`).
Ruff has to be given its settings for the skill scripts, which aren't under them, and an editor's
ruff extension and test panel won't find them for those files without settings of its own. The
usual fix for the editor, a `.vscode/settings.json`, would be a root folder, so it needs its own
decision.

**Options set aside:**

- `pyproject.toml` and `uv.lock` in the root, where Python projects usually keep them: the tools
  would find them without flags, but they and what the tools write would add seven entries to
  the root, and dev-home-tools isn't a package.
- Shortcuts in the root for setup, sync, and update, with the real scripts elsewhere: running
  the real ones is just as easy.
- The tests staying in `internal/tests/`: ruff wouldn't find its settings for them.

**Look again if:** dev-home-tools becomes a Python package, an editor's settings become worth a
root folder, or a `-Configure` switch means nobody edits `local-settings.json` by hand.
