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
  is filled in only in the skill's text. `sync.py` has to run from the clone, so the plugin
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
  config folder, and `update.py` would still pull the clone. Hooks don't need a plugin: setup
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

**Decision:** `templates/shared-skill-scripts/prepare.py` runs the sync inside its own process
(the code of `sync.py`, from `internal/shared/`), then loads `facts.py` into the same process,
checks the skill's stamp, and prints the facts for the topics a skill names. It's the first
command of every skill command that syncs. Skills still commit through `sync.py --message`.

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
- A switch on the sync that also prints the facts: `sync.py` is for people too, while this is
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

## Environment notes follow evidence, not the current session

**Decision:** an environment subsection says where a fact applies, not which session owns the
text. A session may edit any environment's subsection only when it has reliable evidence about
that environment: direct inspection, a fact from the user, output from there, or a project-wide
change that makes an item plainly obsolete. Facts learned locally belong to the current
environment by default, and a session never infers one environment's state from another.

**Why:** limiting a session to its current environment prevents guesses about another one, but
it also blocks corrections the user supplies, facts checked through a remote tool, retiring or
renaming an environment, and removal of notes that a project-wide change made obsolete. The
source of the evidence is the useful safety boundary; the session's location is not.

**Options set aside:**

- Let a session edit only its current environment: safe against cross-environment guesses, but
  leaves known errors and stale notes in every other subsection.
- Let a session edit any environment on judgment alone: easier cleanup, but no boundary keeps a
  fact observed in one environment from being copied to another.

**Look again if:** the evidence rule proves too broad or too narrow in real handoff updates.

## dev-home-tools moves from PowerShell to Python, in phases

**Decision:** the scripts move to Python 3.12 or later, in three phases: 1. the scripts the
skills share, `facts.py` and `prepare.py`, with `prepare.py` still running `sync.ps1`; 2.
`sync.ps1` and `update.ps1`, loaded into `prepare.py`'s process; 3. `setup.ps1`, and then
PowerShell is no longer needed. No phase may add script time: measure each one against the
flow before it, and ask before anything adds time (AGENTS.md's "Speed"). All three phases are
done.

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

**Phase 2, measured:** on the faster PC, a plain `/knowledge`'s `prepare.py` took 1.7 to 1.8 s
in place of 2.2 to 2.5 s, most of it the two GitHub fetches and setup's 0.6 s, which still started
PowerShell. A commit no longer starts PowerShell at all.

**Phase 3, measured:** on the same PC, `prepare.py` took 1.45 to 1.49 s, and setup on its own
0.16 s in place of 0.6 s. What's left is mostly the two GitHub fetches.

**Setup never waits for input nobody can give,** as `setup.ps1` never did. In Python,
`sys.stdin.isatty()` is the wrong check on Windows: it's true for the `NUL` input that agents'
commands get. So: `--quiet` never asks; it asks only when input comes from a real console and
output goes to one (`GetConsoleMode` on Windows, `isatty()` elsewhere), since Python writes a
question to the output, and output sent to a file would hide it; `EOFError` counts as no; and the
tests run setup with input from `NUL` and from an open, silent pipe.

**Phase 3, beyond the port:** setup's settings preview comes from Python's `difflib` in place
of the hand-written diff in `setup.ps1`. It shows the same "Line N:" runs with two lines of
context, and may now and then line up a change differently. And what needs a person (setup's
questions, a yes or no to a settings change, and creating dev-home with gh) now has tests, with
a fake for the person and for gh, where before it was checked only by hand.

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
so not `internal/.generated/`; and sync's and setup's agent commands run through it too, so not
`shared-skill-scripts/`. The dot keeps it apart from the Python code in `internal/shared/`.
Setup's cleanup of the generated files never looks inside a link, so a junction nearby can't
lead it into the Python install.

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
and "skill" keeps them apart from `internal/shared/`, the code behind the scripts in the root,
which `prepare.py` loads the sync from too.

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

## Only the latest versions of Claude Code and Codex

**Decision:** dev-home-tools builds on what the latest versions of Claude Code and Codex read
and document, in every current form that reads what it sets up, and carries no workaround or
fallback for an older version.

**Why:** both tools change their settings and features often. Keeping older versions working
would mean checking each setting against versions nobody here runs, and keeping code and docs
for cases that go away as people update.

**Look again if:** people use dev-home-tools where a tool can't update, such as a managed PC
whose admin holds versions back.

## The tests run on pytest

**Decision:** pytest is the one entry point for the tests. `internal/development/pyproject.toml`
holds the 3.12 floor, a development group (`pytest`, `pytest-xdist`, `pytest-cov`, `ruff`,
`mypy`), and each tool's settings, and `uv.lock` beside it pins them (see "What the root holds"
for why there). `mypy` runs in strict mode and `ruff` checks and formats from the first Python
file. The tests in `internal/development/tests/` share `helpers.py`, and `conftest.py`, which
gives a test that runs a script's code in its own process the script's environment, and checks
the real profile once a worker's tests are done. Fakes only stand in for
what needs a person or an outside service; git and the file system stay real. A test that needs
a fake runs the script's code in the test process, loaded from the sandbox's copy, with
pytest's `monkeypatch`. Coverage is a report run on demand, with no minimum. A test checks that
the scripts use only the standard library, since the test tools are importable when the tests
run them.

**Why:** fixtures share one sandbox among a module's tests, `pytest-xdist` runs the groups in
parallel (the whole suite in about 30 s), and the "needs a person" paths get tests, with small
fakes for the person.

**Options set aside:**

- A plain script, as the PowerShell `Invoke-Tests.ps1` was: every runner feature would be
  written by hand.
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
- `setup.py`, `sync.py`, and `update.py`: people run them by hand. They're short entry points
  that load their code from `internal/shared/`. Python writes a `__pycache__` folder beside any
  file another script loads, and `prepare.py` loads the sync's code into its own process, so
  that code in the root would put that folder there. People run them as `py <path>\sync.py`,
  since the Python install manager's
  `py` is an app execution alias in `%LocalAppData%\Microsoft\WindowsApps`, which Windows puts
  on every user's PATH by default (aliases arrived in Windows 10 version 1709), and as `python3`
  on macOS and Linux. An entry point checks the Python version before anything else, so an older
  Python gets a message instead of a syntax error.
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
- The whole of sync's and update's code in the root, with `prepare.py` loading it without
  writing a cache: it would be compiled again on every skill command, and the code they share
  would still need a folder elsewhere.
- `prepare.py` starting `sync.py` as a process of its own: one more Python start, about 0.03 to
  0.1 s, on every skill command.
- The Python code in a folder of its own, such as `internal/lib/`, with `internal/shared/` left
  to setup's PowerShell files until phase 3: two folders doing one job until then.
- The whole of setup's code in the root: setup runs inside the sync's process too, so the same
  `__pycache__` reason applies.
- The tests staying in `internal/tests/`: ruff wouldn't find its settings for them.

**Look again if:** dev-home-tools becomes a Python package, an editor's settings become worth a
root folder, or a `--configure` switch means nobody edits `local-settings.json` by hand.

## Options take Python's usual form

**Decision:** the Python scripts take long options with two dashes, such as `sync.py --message`
and `update.py --quiet`, each with exactly one spelling: no short forms such as `-m`, and no
shortened names such as `--mess`. Setup's are `--quiet`, `--content-dir`, `--configure`, and
`--what-if`.

**Why:** a skill's pre-approval matches a command's text literally, so a second spelling of an
option could make a command ask first. Every command's text changed in phase 2 anyway, since
`pwsh -NoProfile -File .../sync.ps1` became `<python> -I .../sync.py`.

**Option set aside:** PowerShell's form, `-Message` and `-Quiet`. Python can take it, and it
would look familiar, but it's unusual for Python and out of place on macOS and Linux.

**Look again if:** a tool the skills run in can't pass an option that starts with two dashes.

## One sync at a time, through a lock the operating system holds

**Decision:** `sync.py` locks the file `dev-home-sync.lock` in dev-home's `.git` folder through
the operating system (`msvcrt.locking` on Windows, `fcntl.flock` elsewhere), and waits up to 2
minutes for another run on the same dev-home to let go.

**Why:** the operating system lets go of the lock when the process ends, even one that stops
partway, so no lock is ever left behind for someone to delete. It's in Python's standard
library on every platform, and the file sits inside `.git`, where git ignores it.

**Options set aside:**

- A named mutex, as `sync.ps1` used: Windows only, and Python would need `ctypes` calls to
  reach it.
- A file that exists only while a run holds it: one left by a run that stopped partway would
  stop every sync until someone deleted it.

**Look again if:** dev-home moves somewhere a file lock doesn't hold, such as a network drive.

## A broken step can't stop the update that would fix it

**Decision:**

- `sync.py` loads `internal/shared/update.py` only when it reaches the update check, and reports
  anything that stops it, even an error that keeps it from loading, as a `PROBLEM` line, then
  goes on to setup.
- Each of the sync's other steps (the commit, syncing with GitHub, listing the uncommitted
  files, and setup) runs in a guard: an error in one, such as a bug on a path no test covers,
  is a `PROBLEM` line, and the steps after it still run. A commit that stops still ends the
  sync, so nothing half done is pushed.
- When the code can't load or run at all, the entry points and `prepare.py` print a `PROBLEM`
  line with the commands that install a fix by hand (`git -C <tools> pull --ff-only`, then
  setup), and the README's troubleshooting says the same. `prepare.py` still prints the facts.

**Why:** an update is how fixes arrive, so a bug in the sync must not stop the check that would
install the fix, and a broken sync must never keep an agent from the facts it needs. A guard
costs about 36 ns per sync when nothing fails (measured), against a sync's 1.7 s. Tests break
each part on purpose.

**Options set aside:**

- Only documenting the way out: the likelier failure, an error partway through a sync, would
  still skip the update check every time it happened.
- update's code standing alone, with its own copy of a git runner, status lines, and the
  settings reader, so even a broken `git.py` couldn't stop it: about 40 copied lines, to guard
  against a module that won't load, which the tests catch before any commit.

**Look again if:** the update check moves out of the sync, or a broken shared module ever
reaches a user.

## A sync isolates setup when shared code changed

**Decision:** the sync normally runs setup's code with `--quiet` inside the sync's process, as
it does update's. When `programs.py` loads, it records every Python file's name and modification
time in `internal/shared/`, then checks them again before setup. Setup runs as a Python process
of its own when the sync has just installed an update, or when that check finds a change (tests
check both cases).

The second case covers two overlapping syncs. One can load its modules and wait for the other
to release dev-home's sync lock. If the first sync installs a dev-home-tools update, the waiting
one otherwise has old modules loaded when it reaches the new setup file. The fresh process
loads one consistent version. An unreadable check also counts as a change, since isolation is
the safe choice then. The same rule holds for setup's code as for the rest of
`internal/shared/`: it changes nothing the whole process shares (a test checks), its `main`
never raises, and its step in the sync runs in a guard.

**Why:** each sync used to start a PowerShell process for setup, about 0.6 s of every skill
command that syncs. Starting a Python process instead would still cost about 0.05 s each time.
On this PC, the two small folder scans together took about 0.08 ms.

**Options set aside:**

- Run setup in a Python process of its own every time: simpler isolation, but every skill
  command that syncs pays the process start.
- Accept a rare, recoverable import error and let the next sync repair the generated files: the
  failed run leaves the current setup incomplete and tells the user there is a problem when the
  code can prevent it at negligible cost.

**Look again if:** setup needs something the whole process shares, such as its own current
folder.

## Setup links folders with junctions on Windows

**Decision:** on Windows, setup makes every folder link as a directory junction; on macOS and
Linux, which have no junctions, as a symbolic link. Python makes a junction with
`_winapi.CreateJunction`, part of Python on Windows though not documented for general use;
Python's own tests make junctions with it, and it starts no process.

**Why:** a junction needs no admin rights and no Developer Mode, so every Windows PC gets the
same kind of link, with no branch to write, test, or explain. The Python link was already
always a junction. On macOS and Linux, any user can make a symbolic link, so it's the same
choice there: the one kind of link that needs no special rights. Setup checks only where a link
points, so a symbolic link made by an older setup keeps working.

**Options set aside:**

- A symbolic link where Developer Mode is on, and a junction otherwise, as `setup.ps1` did:
  links that differ between PCs, for no gain.
- Making the junction with `cmd /c mklink /J`: a process each time, and cmd parses its
  arguments again.

**Look again if:** someone keeps dev-home on a network share, which a junction can't point to.

## A dev-home has one active copy, or several

**Decision:** dev-home has two uses, and both are fully supported. With one active copy, it's
private storage with a backup and full history on GitHub: nothing else writes to it, so the local
copy is always the latest. With several, it's the same, plus sharing between the copies, so a
copy can fall behind. A copy is any clone in active use on its own: a PC, a virtual machine, a
container, a remote server, or a cloud environment. Two sessions sharing one clone are one copy,
and a replacement PC whose old copy is retired still makes one. `dev-home.json`, in dev-home's
root, says which, as `{ "multiMachine": false }` or `true`, and the commands act on it:

| Command | One active copy | Several active copies |
| --- | --- | --- |
| `/handoff`, `/handoff <question>` | The local copy. GitHub only to push commits still waiting, and to check once `contentCheckHours` has passed | Fetch first, every time |
| `/handoff update`, `next`, `issue` | Edit, commit, push | Fetch first, edit, commit, push |
| `/knowledge <question>` | The local copy | The local copy |
| Plain `/knowledge` | The local copy, unless `contentCheckHours` has passed: then sync first | The same |
| `/knowledge add` | Add, commit, push | Fetch first, add, commit, push |
| `/dev-home sync` | Fetch, merge, push | The same |

- A new dev-home starts with `multiMachine: false`. When setup clones one set to false, it asks
  whether another copy will stay in use, with no default: the person types y or n, and Enter
  asks again. One set to true stays true, without a question. An older dev-home with no
  `dev-home.json` needs an answer at a console, and `--quiet` says so and changes nothing.
- A missing or unreadable `dev-home.json` means fetching every time.
- With one active copy, a sync that brings in commits this PC didn't make says so in one line,
  naming `/dev-home configure`. It never changes the setting itself: that's a commit every copy
  shares.
- When setup changes the setting, it shows the change, writes only `dev-home.json` (keeping any
  key it doesn't know), and commits and pushes it through the sync's code, in its own process: a
  function that commits the one file and syncs, but skips the update check and setup, since
  setup is already running. It commits before it links skills, so whatever a merge brings in is
  linked in the same run. After a switch to several copies, it tells the person to run
  `/dev-home sync` on the others; before a switch back to one, it asks them to confirm the
  others are retired.
- The sync's lines say what's true for the mode: with one copy, a read never says that dev-home
  may be behind.

**Why:**

- With one copy, a fetch finds nothing, and an offline PC shouldn't be told its own copy may be
  out of date. With several, the start of a session is where a stale handoff costs the most.
- The setting is shared because it describes the repo, and every copy has to agree on it. Kept
  on each PC, every PC would repeat the choice, and one could disagree without anyone noticing.
- Several copies fetch before every command that syncs, with no window of a few minutes in which
  a fetch is skipped. On one PC, a dev-home fetch took about 1.2 s, about 1% of a `/handoff` from
  the prompt to the finished reply, while a stale handoff costs a wrong Next up or work done
  twice. On that PC, over ten days, about half the syncs came within 5 minutes of the one before,
  so a window would have saved fetches, but none a person would notice.
- The clone question has no default because both wrong answers cost something. A wrong "one
  copy" leaves each copy up to `contentCheckHours` behind the other; the line above catches it
  at the first fetch that brings in the other copy's commits. A wrong "several" costs a fetch per
  command for good, and nothing points it out.
- Setup commits through a function of the sync's, in its own process, because a sync that
  commits runs setup when it brought in commits, as a rejected push followed by a merge does.
  Through `sync.py`, setup would start again inside itself.
- `dev-home.json` stands out in the root, says what it configures, and can hold another setting
  for the whole repo later. `multiMachine` is the familiar idea, and defining it by copies in
  active use makes it right for cloud environments and replacements too.

**Options set aside:**

- No setting, with every command that syncs fetching: simpler, but one copy is a first-class
  use, where every fetch finds nothing and an offline read would warn for no reason.
- The setting on each PC only; a shared default with each PC able to override it (rules for
  which wins, with no need for them yet); and a list of the machines (identities to keep up to
  date, when the sync only needs a yes or no).
- Other names: `config.json` (too general), `shared-settings.json` (names how it's stored, not
  what it's for), `multipleCopies` or `multipleClones` (exact, but less familiar), `syncMode`
  (hides the fact that decides the mode), and `syncAcrossMachines` (sounds as if false might stop
  pushes). And a schema version, which nothing needs until the format changes.
- Changing the setting by itself when another copy's commits arrive: a shared commit needs a
  yes.
- A window of 5 or 15 minutes in which several copies skip the fetch.
- A default for the clone question: No (the costlier mistake) or Yes (never pointed out).
- Setup committing through `sync.py --message` in a process of its own with a `--no-setup`
  option (a public option only setup would use, plus a process start), or by running git itself
  (around the sync's lock, its staging of exact files, and its handling of conflicts).

**Look again if:** fetches become slow enough to notice, or the sync needs to know more about the
copies than one or several.

## Commits push first

**Decision:** after a commit, the sync pushes without fetching first. When GitHub rejects the
push because it has commits this copy lacks, the sync fetches, merges, and pushes again, once.
When the push fails for any other reason, such as being offline or signed out, the commit waits,
with no second network call, and the line reads "1 commit saved on this PC, not synced to GitHub
yet. The next sync sends it." A later sync pushes waiting commits even when it skips the fetch.
As before, the sync commits only the files it's given, and never rebases, stashes, resets,
checks out, or discards.

**Why:** a rejected push is git's own sign that a fetch and a merge are needed, so a fetch before
every push found nothing on the usual path. With several copies, a command that edits still
fetches at its start, before the agent changes anything. The line says "synced", the word the
project uses, because it's right in both modes: "backed up" fits only one copy, and "pushed" is
git's word.

**Option set aside:** fetching before every push, as before.

**Look again if:** pushes are rejected often enough that the retries cost more than fetching
first.

## How often the sync checks GitHub

**Decision:** two settings on each PC, in `local-settings.json`, each a whole number of hours,
where 0 means every time:

- `contentCheckHours`, 12 by default: how long a sync with one active copy goes without
  fetching dev-home, and, in both modes, how long plain `/knowledge` reads the local copy before
  syncing first.
- `updateCheckHours`, 24 by default: how long the update check goes without fetching
  dev-home-tools. Between checks, it still reports, or installs when `autoUpdate` is on, the
  commits an earlier fetch found. `update.py` run by hand always fetches, and a sync someone asks
  for, `/dev-home sync` included, keeps to this interval.

Each is timed by its repo's `.git/FETCH_HEAD`, and an empty one counts as no fetch: a fetch that
fails, such as offline, empties the file and still sets its time (tested with git 2.55.0). A
value that isn't a whole number of 0 or more means the default, and setup says so.

**Why:**

- On each PC, because how often a PC reaches GitHub is that PC's choice, such as a laptop on a
  metered connection. Nothing needs the copies to agree, and a change commits nothing.
- With one copy, `contentCheckHours` limits how long a wrong setting, or an edit made on
  GitHub's website, goes unseen. Its default is 12 hours, chosen over the 24 first planned.
- `updateCheckHours` is apart from `autoUpdate`: one says when to check GitHub, the other
  whether to install what a check found. A check on every command found nothing almost every
  time, and fewer checks bring updates in fewer batches, so a session is stopped to reload a
  changed skill less often.
- `FETCH_HEAD` already holds the time, so there's no state file to add.

**Options set aside:**

- Fixed intervals in the code: nobody could change them.
- `contentCheckHours` in `dev-home.json`, shared by every copy: each change would be a commit to
  all of them, with no reason for them to agree.
- A yes or no for the update check: one number covers the default, every time, and anything
  between.

**Look again if:** git changes what a failed fetch does to `FETCH_HEAD`.

## Setup asks each question whose answer isn't saved yet

**Decision:** setup asks each of its questions whenever the answer isn't saved, not only on a
PC's first run, and only when a person can answer (see "Setup never waits for input nobody can
give" above).

- Whether to pull updates automatically: asked until answered. A quiet run leaves `autoUpdate`
  out of `local-settings.json`, and a sync treats a missing answer as no.
- Each `~/.claude-*` folder: asked once. A yes adds it to `claudeConfigDirs`, as before, and a no
  adds it to `declinedClaudeConfigDirs`, so it isn't asked again.
- A quiet run never asks, so it names each `~/.claude-*` folder with no answer, in a line the
  agent passes on. A folder with no answer that the session runs in (`CLAUDE_CONFIG_DIR`) is
  still set up, so that account keeps working, and its settings line says that setup without
  `--quiet` asks about it. A folder with a no is left alone, even from a session there.
- A save keeps every key in `local-settings.json` that setup doesn't know.

**Why:** questions asked only on a first run missed what came later. A Claude folder made after a
PC's first run was never offered, and a first run with `--quiet --content-dir` saved the file
without asking anything, so it looked answered. Naming the folders on every quiet run means an
agent in any account passes the question on: listing them took 0.38 ms at the median, and 5.6 ms
at worst, in 50 runs on one PC, against about 500 ms for a quiet setup.

**Options set aside:**

- For Claude folders: offering every unlisted folder on every run (a no would be asked again
  each time), and asking only on the first run.
- For `autoUpdate`: asking on every run, with the current answer as the default (changing an
  answer later is `--configure`'s job, below), and asking only on the first run.
- For quiet runs: naming only the session's own folder (a new account has no skills linked yet,
  so it would almost never come up), and naming none.
- One map of every folder to its answer, in place of a second list: it would change a format
  already in use, by hand on each PC.

**Look again if:** setup gains a question that shouldn't wait for an answer.

## setup.py --configure changes every setting

**Decision:** `setup.py --configure` is how people and agents change a setting after the first
run: `contentDir`, `autoUpdate`, `updateCheckHours`, `contentCheckHours`, the answer for each
`~/.claude-*` folder, and the shared `multiMachine`.

- At a console, it shows a menu: every setting with its current value, under "This PC" and
  "Shared by every copy of dev-home", in aligned columns, with headings and setup's colors, in
  ASCII like every script. A number changes one setting, `a` goes through all of them with the
  current answers as defaults, and Enter finishes. Each entry asks the question the first run
  asks, so the questions are one piece of code. The Claude folders entry asks about each folder,
  one answered no included, so a no can be taken back.
- An agent can't answer at a console, so it names one setting per run:
  `--configure '<name>=<value>'`, with a plain value, always in single quotes: `true` or `false`,
  a whole number of hours, a path, or `claudeConfigDirs+=<folder>` to set up a folder and
  `claudeConfigDirs-=<folder>` to stop. `--what-if` shows the change first. With neither a
  console nor a setting, it prints the current settings and how to change them.
- A change to `local-settings.json` keeps a dated backup first, as setup's changes to Claude
  Code's and Codex's settings do, and keeps any key it doesn't know. A new `contentDir` never
  moves a folder.
- The `dev-home` skill pre-approves `setup.py --configure *`, as the skills pre-approve
  `sync.py *` for commits: the person's yes in chat to the exact preview is the approval.
- Before it sets dev-home's git config, setup checks that the folder looks like a dev-home: it
  has the files the starter makes, `global-rules/global-rules.md` and `knowledge/README.md`.
  With `--quiet`, it stops when they're missing, before saving or setting anything, and at a
  console it asks for the folder again, where Enter stops. A clone gets the same check before
  setup sets its git config.

**Why:**

- One way to change a setting, so it's checked and written the same way whoever changes it.
- A menu, because a person runs `--configure` to change one thing: it shows every value, and
  changes only what they pick. A question for each setting suits the first run, which needs
  every answer, and `a` keeps that for a full review.
- Plain values, because they reached the script unchanged in every shell tried (2026-10-06:
  PowerShell 7.6.6, Windows PowerShell 5.1, and Git Bash 5.3.9), while Windows PowerShell 5.1
  dropped JSON's inner double quotes, so `["~/.claude-other"]` arrived as `[~/.claude-other]`.
  Single quotes also stop Git Bash from turning a `~` after `=` into a full path. Adding or
  removing one folder means an agent never repeats the whole list.
- A pre-approval with a wildcard, because the value changes with each call. Without one, a
  change would ask three times: the preview, the change, and the question in chat.
- The dev-home check, because setup turns commit signing off in that repo, and an agent can now
  change `contentDir`, so a mistake must not reach a project's repo.

**Options set aside:**

- At a console, every question again with the current answers as defaults: six or more
  questions to change one setting, and a habitual "y" can change the wrong one.
- JSON values (see above); one switch per setting, such as `--content-dir` (the list grows with
  every setting, and a person has to know each one exists); and editing the file by hand only
  (a JSON typo stops setup).
- No pre-approval.

**Look again if:** an agent's tool can answer setup's questions, or the settings outgrow a menu.

## A dev-home skill syncs and configures

**Decision:** a general `dev-home` skill. `/dev-home` alone lists its commands. `/dev-home sync`
fetches, merges, and pushes in either mode, lists the files left uncommitted, and keeps to
`updateCheckHours`. `/dev-home configure` runs `setup.py --configure`: it shows the current
values, previews the exact change, and makes it after the person's yes. Typing `/dev-home sync`
allows a sync, never a commit: it offers to commit a `STALE` file, and leaves a `LEFT` one alone
unless the person says it's theirs. In Codex, both say which command to run in a terminal, and
change nothing, while Codex can't use git's and gh's sign-ins.

Plain `/knowledge` stops being the sync someone asks for. It reads the local copy, unless
`contentCheckHours` has passed, when it syncs first, in both modes. `/knowledge <question>` still
never syncs.

**Why:** one place to sync and configure that's easy to find, with room for more dev-home
commands without a skill for each. `/dev-home` alone lists rather than syncs, so typing the name
never reaches the network unasked. Plain `/knowledge` is a lookup, so it follows the lookups'
rule, with a check at the interval so its list of subjects is never far behind.

**Options set aside:** a skill only for syncing; plain `/knowledge` syncing as before (a fetch
when the person only wanted the list of subjects); and plain `/knowledge` never checking at all.

**Look again if:** the skill gathers commands that don't belong together.

## /dev-home skills lists the skills dev-home sets up

**Decision:** `/dev-home skills` lists every skill setup sets up: dev-home-tools' own, then the
person's from `skills/` in dev-home, each with whose it is and its description. It says when one
of theirs isn't set up because a dev-home-tools skill has its name, as setup does. The list comes
from a `skills` topic in `facts.py`, so it reads only this PC's files, never syncs, and works in
Codex too.

**Why:** turning skills on and off is planned, with a default set that dev-home-tools chooses,
so some of its skills may ship turned off, and this list is where people find them. Listing takes
no judgment, so it belongs in a script (see AGENTS.md), and a `facts.py` topic is one
pre-approved command that costs a Python start only when someone types it. `skills` names what
it shows, and turning skills on and off can sit under the same word later.

**Options set aside:**

- Also listing skills in the tools' own folders that setup didn't put there, or every skill
  installed, such as Anthropic's synced skills, plugins, and Codex's `.system` skills: they
  aren't dev-home's, and each tool can list its own.
- Only the person's own skills: dev-home-tools' skills that ship turned off couldn't be found.
- `/dev-home list`: a general verb, which would need a second word once anything else is listed.
- Showing where each skill is linked: `facts.py` would need a second copy of setup's rules for
  which Claude folders it sets up, and setup already reports a link problem on every sync.

**Look again if:** skills can be turned on and off, when the list should show each one's state,
or people need to see where each skill is linked.

## The handoff update checks issue links with one script

**Decision:** `/handoff update` finds out whether linked GitHub issues have closed with one
script in the handoff skill's folder, not a `gh issue view` for each link. The script finds the
handoff from the folder it runs in, as `facts.py` does, reads every issue link in it, checks
them all with one `gh` request, and prints a line for each: closed, with GitHub's reason; open;
or not checked, and why, such as `gh` missing or signed out. The agent runs it in the same turn
as its read of the handoff just before editing, so it costs no extra turn. It never runs for a
read, `next`, or `issue`. It adds one Python start, about 0.04 s, and replaces a `gh` process
for each link with one.

**Why:** reading a link and checking its state takes no judgment, so it belongs in a script (see
AGENTS.md). One call covers any number of links. When issues on GitLab, Bitbucket, or Azure
DevOps come, it's the one place that learns each host's tool, so the skill's steps don't grow
with each host. Its lines can be tested with a faked `gh`.

**Options set aside:**

- Keeping a `gh issue view` for each link: each new host would add steps to the skill.
- Checking issues in the update's start-up call: about 0.04 s faster, and never a call of its
  own, but the update would need a start-up command of its own, and `prepare.py`, which every
  skill shares, would take on a network job for one skill.
- Waiting for a second host before writing the script: one call, testable lines, and shorter
  steps help with GitHub alone.

**Look again if:** reads should show closed issues too, which would put a network call on every
read.

## Setup offers recommended settings for Claude Code and Codex

**Decision:** setup offers settings that dev-home-tools recommends for the tools, from a list in
`templates/recommended-settings/recommended-settings.json`. Each entry has an id that is never
reused, what it does, why it's recommended, and the setting for each tool that has one. The first
two are for Claude Code: `"attribution": false` (id `attribution-off`), which leaves commits and
pull requests without a line naming the tool, and `"feedbackSurveyRate": 0` (id
`feedback-survey-off`), which stops the session quality survey and its request to upload the
session's transcript.

- Setup offers one only for a Claude folder whose `settings.json` lacks that setting. A value
  already there, whatever it is, is the person's own choice, and setup never asks about it or
  changes it.
- Answers are saved per PC and per Claude folder, in `local-settings.json` under
  `recommendedSettings`, such as `{"~/.claude": {"attribution-off": true}}`. A no is never asked
  again. An answer is saved only once its change is written, so a run that stops partway records
  nothing.
- A settings file gets one diff for everything setup changes in it, the required lines and the
  chosen recommendations together, with one yes and one backup.

**Why:** these settings suit most people, but each changes the person's own file, so each needs
their yes on each PC. Codex has neither: its commit and pull request attribution is a setting of
the ChatGPT workspace, which Codex asks OpenAI for, and it has no session survey (checked in
Codex's source at rust-v0.161.0, 2026-10-07). `"attribution": false` needs Claude Code 2.1.281
or later, which "Only the latest versions of Claude Code and Codex" allows. Answers are per
folder because a work account can need different settings, and a saved yes never causes a later
write by itself, so setup never undoes an edit the person made.

**Options set aside:**

- Answers shared in `dev-home.json`: every PC still needs its own yes to change its files, so
  sharing saves only a question, and adds a second record that can disagree with what a PC's
  answer was. Recommendations tied to what a PC has installed don't fit a shared answer at all.
- One answer for every Claude folder on a PC: a folder set up later would be changed without
  being asked.
- The three-key form of `attribution` (`commit`, `pr`, and `sessionUrl`), which only older
  versions of Claude Code need.
- Turning off telemetry: in Claude Code it also stops feature flags, which can make Remote
  Control unavailable, so it's not a safe default for everyone.

**Look again if:** Codex gains a local setting for attribution or a survey, or Claude Code's
settings start syncing between machines.

## One prompt for every optional list

**Decision:** every list of optional items setup offers, recommended settings and skills now and
later lists such as example rules, is asked with one prompt: **All**, **All recommended** (the
default, which Enter takes), **None**, or **Ask for each**, where each item's question defaults to
whether it's recommended (`[Y/n]` or `[y/N]`). All is left out when it would do the same as All
recommended. The prompt covers only the items not answered yet, and chat offers the same four
answers.

**Why:** one prompt to learn, however long the lists grow, and each new list costs only its
catalog. Someone in a hurry presses Enter, and someone careful goes through each. With every
default matching the recommendation, pressing Enter can never record a choice dev-home-tools
doesn't recommend.

**Options set aside:** a question for each item (a long run of questions as the lists grow); all
or nothing (no way to pick); and no default (a hurried Enter would only ask again).

**Look again if:** a list needs answers other than yes or no for each item.

## A run of setup by hand asks what's unanswered, then shows every setting

**Decision:** every run of `setup.py` at a console goes in this order:

1. dev-home first: its folder, then, when it's missing, clone or create it, with the repo's name,
   after checking that `gh` is there and signed in. If that fails, setup stops and saves nothing.
2. The questions not answered yet: extra Claude folders and Codex homes, automatic updates, the
   copies question, skills, recommended settings, and each settings file's diff. The copies
   question is always asked on a PC's first setup, with `dev-home.json`'s answer as the default,
   since adding a PC is when that answer most often changes. Wherever a saved answer exists, a
   question shows it as the default.
3. The settings list that `--configure` shows, with skills and recommended settings added, so any
   setting can be changed: a number for one, `a` for all, and Enter to go on.
4. The work, without stopping: save this PC's answers, commit `dev-home.json` if it changed, then
   the Python link, the generated files, the skill links, the rules, and the settings files. Each
   settings file is read again first; if it changed since its diff was shown, setup shows the new
   diff and asks again.

Setup also detects which tools a PC has, Claude Code when `~/.claude` exists and Codex when
`~/.codex` does, instead of always setting up `~/.claude`.

**Why:** running setup by hand is a normal way to use dev-home-tools, so it should offer every
setting, not only the unanswered ones. Questions first and the work after is what people expect
from a setup program, and keeps every question in one place as the lists grow. dev-home comes
first because later steps need it, and only the questions the clone needs come before it, so a
clone that can't work stops setup after one or two answers. Committing `dev-home.json` after the
questions, not between them, means nothing has been pushed until the work starts, so Ctrl+C
during the questions leaves everything as it was.

This changes two entries above: the menu from "setup.py --configure changes every setting" becomes
part of every run by hand, and the copies question from "A dev-home has one active copy, or
several" is asked on every PC's first setup.

**Options set aside:**

- Asking at each step, as before: questions mixed into the status lines, easy to miss.
- Every question again on every run, with the current answers as defaults: a long run of Enters
  as the lists grow.
- Every question before the clone, checked afterward: the copies question would be asked blind on
  the usual way to add a PC, and personal skills can't be listed before the clone.
- Skipping the copies question when `dev-home.json` answers it: moving to a new PC and retiring
  the old one would leave it at several copies for good.

**Look again if:** a question comes to depend on work that setup does after the questions.

## Setup installs skills per PC, and the tools show or hide them

**Decision:** setup decides which skills are installed on each PC, meaning linked into each Claude
folder's `skills/` and into `~/.agents/skills` for Codex. Claude Code's and Codex's own menus
decide whether an installed skill is shown in an account or a project.

- Each PC saves a yes or no for each skill in `local-settings.json` under `skills`. A no removes
  setup's links for it, and its lines leave the generated always-on rules. Nothing is deleted.
- `dev-home` is always installed. `handoff` and `knowledge` are recommended because the starter
  dev-home makes their folders, so a change to the starter means looking at this set again.
- The person's own skills, from `skills/` in dev-home, work like recommended skills: installed by
  default, in the same list and prompt, and asked about once on each PC.
- A skill can carry a `dev-home-skill.json` in its folder, with `recommended`, `alwaysInstalled`,
  and `requires` (`tools`, `programs`, and `os`). A skill whose requirements a PC doesn't meet
  isn't installed there, even with a yes, and setup says why. For the person's own skills the
  file is optional: without it, a skill is recommended and needs nothing.
- `/dev-home skills` shows each skill's state. Codex records a skill turned off by its real path,
  inside `internal/.generated/skills/`, so that path stays fixed, and a test checks it.

**Why:** checked on 2026-10-07 against Claude Code 2.1.293's docs and Codex's source at
rust-v0.161.0:

- Both tools have their own switch, saved on each PC and never synced. Claude Code's `/skills`
  menu writes `skillOverrides` to the current project's `.claude/settings.local.json`, and for a
  whole account `skillOverrides` goes in that account's `settings.json`. Codex's `/skills` writes
  `[[skills.config]]` entries to that Codex home's `config.toml`, and reads none from a project.
- So dev-home-tools adds what the tools lack, a choice of what a PC has at all, and leaves showing
  and hiding to them. The two answer different questions, so they can't disagree, and
  dev-home-tools never writes the tools' switches.
- Some planned skills suit only some setups, such as one for each work tracker, and some can't
  work everywhere: ones that use Claude Code-only features, need a program such as `gh`, or work
  on one OS. Only an install step keeps those off a PC.
- Per PC, because the tools' own choices are per PC, and a skill for one setup belongs on that PC.
- Both tools list every installed skill's name and description in every session, within 1% of the
  context window in Claude Code and 2% in Codex, so a skill a PC doesn't use costs tokens there.
- A file in the skill's folder rather than its frontmatter: dev-home-tools' skills and the
  person's own work the same way, setup reads JSON with Python's standard library, and a skill
  copied from elsewhere will need a file of its own anyway, to record where it came from.

This changes "/dev-home skills lists the skills dev-home sets up", whose list now shows each
skill's state.

**Options set aside:**

- The tools' switches only: a skill dev-home-tools doesn't recommend would be linked and listed on
  every PC until turned off there.
- dev-home-tools' own on and off, ignoring the tools': two switches with the same meaning, which
  could disagree.
- Choices shared in `dev-home.json`, or per PC with shared defaults: a skill for one setup would
  follow to every PC, at the cost of commits and merge conflicts.
- `metadata` in the frontmatter: setup would need to read YAML without a library, and marking a
  skill copied from someone else would edit their `SKILL.md`.
- The person's own skills always installed: one made for one PC could only be hidden per tool and
  per account.

**Look again if:** people find themselves making the same choices on every PC, when a one-time
copy of another PC's choices could help, or a tool starts syncing skill choices.

## New items reach the person at a terminal, or in a NEW line

**Decision:** an update or a sync can bring new items: a dev-home-tools skill or recommended
setting, or a personal skill made on another PC.

- When `update.py` runs at a console, the setup it runs afterward does too, and asks about the new
  items right then.
- A quiet sync installs a new recommended skill or personal skill, and nothing else. From then on,
  every sync prints one line with the status word `NEW`, summing up what's new and what's waiting,
  until the person answers, None included. The exit code stays 0. Skills pass the line on once
  per session, as a line of its own.
- One answer covers a batch, with the shared prompt's four choices, in chat or at the next run of
  setup by hand, whichever comes first. A recommended setting still shows its diff and needs a
  yes.
- Quiet runs write nothing for this.

**Why:** a line printed once is easy to lose in an agent's reply, and the agent decides what to
pass on, while a new skill is already at work in every session. Repeating it until answered, once
per session, means nothing is missed, and one answer, even no, ends it. `PROBLEM` would say
something is broken, and set the exit code. When the person is at a terminal, asking right then
is clearest.

**Options set aside:**

- One line, the first time only: easily lost, and a new skill would be at work before the person
  heard of it.
- Saving that the line was shown: quiet runs would start writing `local-settings.json`.
- Nothing in syncs, only at the next run by hand: weeks could pass.
- A line for each item: a batch, such as after months without updating or from a set of copied
  skills, would flood the reply.

**Look again if:** the reminders come to feel like noise, such as many new personal skills a week
across several PCs.

## Setup finds extra Codex homes as it finds extra Claude folders

**Decision:** setup finds each `~/.codex-*` folder that holds a Codex `config.toml` or
`auth.json`, and the folder `CODEX_HOME` names when setup runs from a Codex session. It asks once
about each, and saves the answers in `codexHomes` and `declinedCodexHomes` in
`local-settings.json`. A yes gets that home what `~/.codex` gets: the always-on rules in its
`AGENTS.md`, and dev-home in its `config.toml`. A home elsewhere can be added by its path.

**Why:** Codex reads its folder from `CODEX_HOME`, which can point anywhere, and each home has its
own `config.toml`, `AGENTS.md`, and sign-in. Every home on a PC shares `~/.agents/skills` (Codex's
source at rust-v0.161.0), so a second home already sees dev-home-tools' skills, but without the
rules they depend on, and with dev-home's writes blocked by Codex's sandbox. Half set up is worse
than not set up. Finding and asking the same way as for Claude folders keeps one rule for both,
and listing `~/.codex-*` costs about what listing `~/.claude-*` does.

**Options set aside:** adding homes by path only (most people would never learn the option
exists), and supporting `~/.codex` only.

**Look again if:** OpenAI adopts a naming convention for extra homes, or Codex's desktop app or
IDE extension turns out not to honor `CODEX_HOME`, which hasn't been checked.

## --configure applies a recommended setting after a yes in chat

**Decision:** `setup.py --configure` can apply a recommended setting to a tool's settings file,
not only change dev-home-tools' own settings. With `--what-if`, it prints the diff for each file
and a fingerprint of that preview. The agent shows it, the person says yes in chat, and the agent
runs the same command with the fingerprint. Setup writes only if the files still match what was
shown, with a backup as usual. Only values from the recommended-settings list can be applied this
way, never an arbitrary key, and the `dev-home` skill keeps pre-approving
`setup.py --configure *`, as the skills pre-approve their commits.

**Why:** chat is where most later questions reach people, between runs of setup by hand. The
fingerprint makes a yes in chat as exact as a typed yes, as `update.py` pulls exactly the commit
it showed. If Claude Code changed the file in between, such as through `/config`, nothing is
written.

**Options set aside:** the console only (every later recommendation would need a terminal), and
chat without the fingerprint (a changed file could be written with something the person didn't
see).

**Look again if:** an agent's tool can show a diff and take the yes itself.

## Offers use the same answers

**Decision:** every question that offers something a person can take or turn down uses the same
answers, built and planned offers alike: issue and knowledge candidates, setup's optional lists
(skills, recommended settings, example rules), the `NEW` line, dev-home-tools updates, starter
updates, and copied skills. Two terms:

- **Session:** one conversation with an agent. A new conversation, or `/clear`, starts a new
  one; resuming a conversation continues it. At a terminal, one run of setup is one session.
- **Trigger:** the moment a question comes up, which each offer defines, such as a
  `/handoff update` in which the session changed the item, or every session until answered for
  a `NEW` line.

| Answer | Remembered | Asked again |
| --- | --- | --- |
| Yes, in the offer's own words, such as "Create a GitHub issue for it" | It's done | Never, for that item |
| Skip (no reminder) | Nothing | Not in this session; later only when its trigger fires again |
| Remind me next session | Yes | The first time it comes up in a later session |
| Remind me in N days | Yes, with the date | The first time it comes up on or after that date |
| No (never ask again) | Yes | Never, for that item; for an item with versions, a newer version is a new offer |

- The yes answer says what it does and where, never only a verb such as "File it".
- Nothing is asked twice in one session, whatever the answer. Saying nothing changes nothing, not
  even an earlier answer: a reminder that's due stays due, so a later session asks again. Skip,
  by contrast, ends a reminder.
- A list of items of one type adds All, All recommended (when items have recommendations),
  None, and Ask for each, which asks the answers above for each item. Skip and the reminders
  can also answer the whole list. Items of different types are never in one list: each type
  gets its own question.
- A question lists only the answers that do something different for it, each with its note in
  parentheses, so it explains itself. A `NEW` line comes back every session anyway, so it offers
  no "remind me next session". That's part of the standard, not a departure.

**Departure:** approving exact text, such as a draft's "Save, commit, and push this?" or a
settings diff's typed yes, stays yes or no. It's one change shown once, not an offer that comes
back.

**Why:** the offers grew one at a time, with different words for the same idea ("decide later",
"remind me later", "skip this version"), and "later" never said when. Defining each answer by
what's remembered and when it comes back makes every question mean the same thing. One type per
list keeps a quick "All" from accepting something the person didn't look at.

**This changes:**

- "One prompt for every optional list": it gains skip and the reminders, and different types
  are asked separately.
- "New items reach the person at a terminal, or in a NEW line": one answer covers a batch of one
  type.
- Issue candidates: "File it, decide later, or no?" becomes these answers.
- Knowledge candidates: they gain the reminders and a remembered no, where a no now lasts only
  for the session and nothing records it. Both need a record in dev-home of the finding and its
  evidence; where is decided when it's built.

**Options set aside:** a "later" with no time (nobody can tell when it comes back); "not now"
beside "remind me later" (both sound like a reminder will come); one answer for a list of mixed
types.

**Look again if:** an offer needs an answer these don't cover.
