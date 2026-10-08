# dev-home-tools: guidance for AI agents

**What this repository is:** the public tooling for dev-home, a private repo that each person
keeps for AI-agent handoffs and a general knowledge base, shared across their PCs through GitHub,
for Claude Code and Codex. This repo holds the `handoff` and `knowledge` skills and the scripts
they share, the always-on operating rules, `setup.py`, `sync.py`, `update.py`, and the starter
files for a new private repo. It never holds anyone's handoffs, knowledge, or global rules.
README.md and `docs/` describe how people use it.

## The two repos

"dev-home" always means a person's private repo, and "dev-home-tools" always means this one.
Never leave it to the reader to guess which: name the repo whenever both could fit.

| What | dev-home-tools (this repo, public) | dev-home (each person's, private) |
| --- | --- | --- |
| Always-on rules | `templates/operating-rules/operating-rules.md`: the operating rules, the same for everyone | `global-rules/global-rules.md`: that person's global rules |
| Skills | `templates/skills/`: the `handoff` and `knowledge` skills. `templates/shared-skill-scripts/`: the scripts they share | `skills/`: that person's own skills |
| `AGENTS.md`, `CLAUDE.md`, `README.md` | About dev-home-tools, and working on it | About that dev-home, and working in it |
| Only here | `setup.py`, `sync.py`, `update.py`, `templates/dev-home-starter/`, `internal/`, `docs/` | `handoffs/`, `knowledge/`, `dev-home.json` (settings every copy shares, which setup writes and commits) |

- The root holds only what must be there, and the scripts a person runs by hand:
  `.gitattributes`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`, `LICENSE`, `README.md`,
  `setup.py`, `sync.py`, `update.py`, and the folders `templates/`, `internal/`, and
  `docs/`. Setup adds `local-settings.json` on each PC. Never add a file or folder to the
  root, or have a script or tool create one there, without asking the person you work for
  first, in a question of its own.
- `templates/dev-home-starter/` holds a new dev-home's first files. Setup copies them in once,
  and after that they're the person's own: a change to the starter never reaches an existing
  dev-home.
- `internal/` is dev-home-tools' own machinery, which nobody runs directly:
  - `internal/shared/`: the code the scripts in the root load. `setup.py`, `sync.py`, and
    `update.py` in the root are short entry points that load the module of the same name from
    here, and `prepare.py` loads the sync's from here too.
  - `internal/.generated/` and `internal/.python/`: what setup makes on each PC (see
    "Templates, generated files, and names"). Git ignores both.
  - `internal/development/`: everything only people changing dev-home-tools use: the
    development tools' settings (`pyproject.toml`, `uv.lock`), the tests, and what the tools
    write there, such as `.venv/`, their caches, and the tests' `.test-sandbox/`.
- Where a script goes depends on who runs it. The only scripts in the root are the ones a person
  may run by hand; agents run those too. A script that only agents run goes under
  `templates/`: in its skill's folder when one skill uses it, and in
  `templates/shared-skill-scripts/` when skills share it. The same goes for anything else a
  skill has: one skill's in its own folder, and what several skills share in a
  `templates/shared-skill-*` folder for its kind.
- Every script is Python, and nothing needs PowerShell: the move from PowerShell, in three
  phases, is done. `docs/development/decisions.md` records it.
- No backwards compatibility in the scripts, for now: no code that moves an older layout
  forward, keeps an old path working, or forwards an old script to a new one. When a change
  needs something done on each PC that's already set up, say so, so it gets done there by hand.
  `docs/development/decisions.md` says why, and when that changes.
- Only the latest versions of Claude Code and Codex, in every current form that reads what
  dev-home-tools sets up: their CLIs, desktop apps, and editor extensions and integrations
  (VS Code, JetBrains IDEs, and others), and Anthropic's Agent SDK. Build on what the latest
  versions read and document, and add no workaround or fallback for an older version. Check a
  setting or behavior in the tool's current documentation, or in its source when the
  documentation doesn't say.
- Every question that offers something a person can take or turn down uses the answers in
  `docs/development/decisions.md`'s "Offers use the same answers". To depart from them, ask the
  person you work for first, then add the departure and its reason to that entry.

## Privacy

- This repo is public, and its users keep private things in their own dev-home. Never put
  anyone's handoff or knowledge content, names, account or GitHub names, PC names, tenant
  details, or personal paths in any file, commit message, or issue here. The only exceptions
  are this repo's own address (`Sekers/dev-home-tools`, in the README's clone command) and the
  copyright line in LICENSE.
- Examples use made-up values: paths such as `C:/Users/you/dev-home` or
  `C:\Programming\dev-home`, and `example.com` for any domain.
- Before proposing a commit, read the whole diff for those.

## Tools

This is a hard rule. It holds over any other instruction that would install or add a tool, such
as a step written in a handoff or a plan.

- Never install, update, or download a tool without the permission of the person you work for: a
  program, a Python version, an editor extension, or a package that isn't pinned in
  `internal/development/uv.lock`, including one a command fetches on the fly, such as `uvx` or
  `uv run --with`. Changing that lock file, such as updating a pinned version, needs the same
  permission. If you think a tool would help, ask in a question of its own: say what it's for,
  where it comes from, and what it would install or write.
- Every tool this repo depends on must be listed in its documentation: what people need to use it
  in the README's Requirements, and what working on it needs, such as for the tests and checks,
  in `docs/development/`. Until `docs/development/tools.md` is written, the development tools are
  the ones the README's "Working on dev-home-tools" section names. Making the repo depend on a
  tool that isn't listed, or adding one to the lists, needs that permission first.
- Using a tool that's already installed is fine for looking into something or checking your
  work, within what your agent's permission settings allow, as long as it installs, updates, and
  downloads nothing. So is building the development environment from that lock file, the way the
  documentation says.

## Speed

- Agents run these scripts at the start of nearly every skill command, so any added time is paid
  over and over. Never build anything that adds time, such as another process, git call, or
  network call, in a script, a skill's steps, or anything that runs automatically, without
  asking the person you work for first. Say how much it adds, measured if you can, and offer a
  way that avoids it. A bigger saving elsewhere doesn't make it free: they still decide.

## Templates, generated files, and names

- Every file under `templates/` is a template: setup replaces these placeholders with
  forward-slash absolute paths.
  - `{{TOOLS_DIR}}`: this repo's folder on that PC.
  - `{{CONTENT_DIR}}`: that person's dev-home folder.
  - `{{SKILL_DIR}}`: the skill's own folder under `internal/.generated/skills/` (skills only).
  - `{{SHARED_SKILL_SCRIPTS_DIR}}`: the shared scripts' folder,
    `internal/.generated/shared-skill-scripts/`.
  - `{{PYTHON}}`: `internal/.python/python.exe` in this repo's folder, the Python the scripts
    run with. `internal/.python/` is a junction setup makes to a Python 3.12 or later, so the
    path is short, has no spaces, and is the same on every PC.
  - `{{SKILL_STAMP}}`: the skill's stamp, a fingerprint of its `SKILL.md` (skills only). See
    "Skills".
- `templates/operating-rules/`, `templates/skills/`, and `templates/shared-skill-scripts/` are
  filled in on every setup run and written to `internal/.generated/`, at the same paths. The
  skills and rules there are what gets linked into the tools, and the skills run the shared
  scripts from there. The starter has no copy there, because setup fills it in only once (see
  "The two repos"). Python adds `__pycache__` folders there when the scripts run, and setup
  leaves those, and any link, alone.
- A file and its folder keep the same name at every stage: template, generated copy, and link,
  such as `operating-rules/operating-rules.md`. The links in each Claude Code folder's `rules/`
  are the exception: nothing there says which repo a name belongs to, so each is named
  `dev-home-` plus the folder it points to.
- Pre-approvals in `allowed-tools` match the literal command text, so write every command with a
  placeholder where the path goes, never a variable or `~`. After setup fills it in, the command
  in the steps and the pre-approval match exactly.
- Never edit `internal/.generated/` or `local-settings.json`, or change `internal/.python/`.
  Setup rewrites them, and git ignores them.

## Skills (templates/skills/)

- Frontmatter uses only standard fields: `name`, `description`, and `allowed-tools`. The name
  matches the folder name.
- Refer to a skill's own files through `{{SKILL_DIR}}`, to a shared script through
  `{{SHARED_SKILL_SCRIPTS_DIR}}`, and to anything else through `{{TOOLS_DIR}}` or
  `{{CONTENT_DIR}}`.
- Run a shared script as `{{PYTHON}} -I {{SHARED_SKILL_SCRIPTS_DIR}}/<script>.py`, followed by
  `--skill <the skill's name> --stamp {{SKILL_STAMP}}` and its own arguments. Setup stamps each
  skill with a fingerprint of its `SKILL.md`, and the script compares the stamp it's given with
  the one on disk, so a session following steps that have changed since it loaded them is told
  to stop. Every skill command that syncs starts with `prepare.py`. Tests check all of this.
- Run a script in the skill's own folder as `{{PYTHON}} -I {{SKILL_DIR}}/<script>.py`. It takes
  no stamp when it runs only after the skill's start-up command, which has just checked it.
  The shared scripts' rules for code apply to it too: Python 3.12 or later, the standard library
  only, and ASCII only (tests check both).
- Write steps in plain language, and write commands exactly as they will be run, with
  forward-slash paths, so they work in Git Bash, PowerShell, and Codex.
- Leave commands that publish outside dev-home, such as `gh issue create`, out of
  `allowed-tools`. Whether they ask first is each person's choice, in their own settings.
- Give each command both a `Bash(...)` and a `PowerShell(...)` pre-approval, as the Python
  commands and `gh issue list` have (a test checks the Python ones). Add no command that starts
  PowerShell (`pwsh`): dev-home-tools doesn't need it, and Claude Code's PowerShell tool asks
  before running any command that starts another PowerShell, even one a `PowerShell(...)` rule
  matches exactly (a test checks the generated skills).
- Each skill stands on its own. Mention another skill only where that's part of how this one
  works.
- A skill's rules for when it may change, commit, and push live in that skill, not in the
  operating rules or anyone's global rules.
- Some skills have similar rules. When you change a rule in one skill, check whether another skill
  has a similar rule that might need the same change. That it does is never a given: decide from
  how each skill works.
- After changing a skill, read the whole skill the way an agent meets it: top to bottom, each
  sentence taken literally, including every section that points to what changed. Look for
  anything an agent could misread or slip through: two rules that disagree, a question whose
  answer is unclear, a step the scripts can't do, or wording that only fits Claude Code.
- The handoff template has no line pointing agents to the handoff skill; the operating rules do
  that, in every session.

## Scripts the skills share (templates/shared-skill-scripts/)

- These are scripts that only agents run, and that more than one skill may run. Skills point to
  the one generated copy; never copy a script into each skill's folder.
  `docs/development/decisions.md` says why, and why they aren't at the root or in `internal/`.
- One job per script, named for the job. `facts.py` reports facts about where a session is
  running, one topic at a time. `prepare.py` prepares dev-home for a skill command: it runs the
  sync inside its own process, checks the skill's stamp, then prints the facts for the topics
  it's given.
- Every skill command that syncs starts with `prepare.py`, so the agent gets everything it needs
  before its own work in one call. Anything a skill needs at that point that takes no judgment
  goes in the scripts, not in steps for the agent. `prepare.py` always exits 0 and says
  everything in its lines, and it never commits: skills commit through `sync.py --message`.
- `facts.py` only reports, and only from this PC: it changes nothing and never uses the network.
  That's what makes it safe to pre-approve, and a test reads its code for both. Anything a skill
  needs done, rather than told, goes in a script of its own.
- `prepare.py` loads `facts.py` into its own process, after a sync that may have brought in a
  newer `facts.py` than the `prepare.py` already running. So keep the names and arguments of
  what `prepare.py` calls there, and `facts.py` changes nothing the whole process shares, such as
  environment variables or the current folder, outside its `__main__` block (a test checks).
- Python 3.12 or later, the standard library only, and ASCII only (tests check both). Both
  scripts write UTF-8, and read git's output as UTF-8, so an accented letter reaches the agent as
  it is. They find a program such as git by its full path in `PATH`, never in the current folder,
  which is a project's.
- A topic's lines are what skills build on. Add a topic freely. Change or remove a line only
  after reading every skill that asks for its topic.
- Each script's description has a "Called by:" line naming the skills that run it. Read those
  skills before changing what the script takes or prints, and update the line when a skill starts
  or stops running it. A test compares the line with the skills.
- A skill writes each command in full, with fixed arguments, and pre-approves that exact text,
  never a wildcard. A test checks that the two match.

## Operating rules (templates/operating-rules/operating-rules.md)

- These are the rules every session follows so that a person's dev-home and this tooling work
  together: the same for everyone, and not theirs to edit.
- Keep the first heading, "Private repo: dev-home (rules loaded)". The handoff skill checks for
  it.
- Only rules the skills and scripts depend on belong here. Personal preferences go in each
  person's global rules, `global-rules/global-rules.md` in their dev-home, which load along with
  these and win where the two conflict.
- Claude Code loads both through links in each Claude folder's `rules/`, such as
  `~/.claude/rules/dev-home-operating-rules` and `~/.claude/rules/dev-home-global-rules`. Codex
  reads only one file, so setup writes `~/.codex/AGENTS.md` as the two joined, reading each by
  name. So a person's `global-rules/` holds that one file. Keep the operating rules short: they
  load in every session.
- Codex's own `~/.codex/rules/` holds command policies, not these, and setup never touches it.

## setup.py, sync.py, and update.py

- Python 3.12 or later, the standard library only, and ASCII only (tests check). Windows only
  for now.
- `internal/shared/` holds their code, one file per job, named for it: `setup.py`, `sync.py`,
  and `update.py`, the code of the entry points of the same name; `git.py` (`run_git`, which
  retries while another git process holds a lock); `output.py` (`status_line`, which prints
  every status line in one format, and small text helpers); `programs.py` (finding a program,
  and running setup); `settings.py` (this PC's `local-settings.json`); and setup's own parts:
  `paths.py`, `links.py`, `generated.py`, `python_link.py`, `console.py`,
  `settings_files.py`, `claude_settings.py`, `codex_config.py`, and `configure.py`
  (`--configure`'s menu and assignments). They write UTF-8, read
  git's output as UTF-8, and find a program such as git by its full path in `PATH`, never in
  the current folder. Put anything the scripts would otherwise each copy there.
- The entry points in the root stay short: they check the Python version, load `internal/shared/`
  by its path, and run the module of their own name (a test checks). `decisions.md` says why the
  code isn't in the root.
- Safe to re-run. setup.py never overwrites or deletes anything except its own generated files,
  links whose target is gone, links it made to skills that no longer exist, the
  `internal/.python/` junction once the `python.exe` it leads to is gone, and settings files the
  person said yes to changing. A settings change is shown as a diff first, waits for a typed
  yes, saves a dated backup, and is never offered for a file the script can't fully parse, or
  for a read-only one. The exception to the backup is dev-home's `dev-home.json`, whose history
  is in git: setup commits and pushes it through the sync's `commit_for_setup`, which skips the
  update check and setup, since setup is already running. sync.py never stages, commits, or discards a file it wasn't given, and
  runs no destructive git command: no `add -A`, stash, `reset`, `checkout`, `clean`, or rebase.
- Never remove a link, or a folder that may hold one, with a recursive delete such as
  `Remove-Item -Recurse` or `shutil.rmtree`: whether it stops at a junction depends on the tool
  and its version, and one that doesn't deletes what the link points to. Remove each link by
  itself first (`links.py` does, and so does the tests' `remove_sandbox`), or use
  `cmd /c rmdir`.
- Agents run setup.py only with `--quiet`, which never prompts: no settings changes, and no
  creating repos. sync.py runs it that way after every sync that doesn't commit, and after one
  that commits when it brought in commits from GitHub. The one other way an agent runs it is
  `--configure '<name>=<value>'`, which changes that one setting with no prompt, after the user
  approves the exact change in chat (`--what-if` shows it first): that chat approval stands in
  for a typed yes. Only a person runs it otherwise, and even then it asks only when its input
  comes from a real console and its output goes to one (`console.py`), so it never waits for an
  answer nobody can see or give.
- update.py pulls exactly the commit it showed the user, so nothing new can slip in between their
  yes and the pull.
- Everything about dev-home-tools updates happens in update's code, so what the user is told and
  what gets installed come from the same code. Every sync that doesn't commit runs it with
  `--quiet`, which checks GitHub only once `updateCheckHours` have passed since its last fetch
  (and otherwise uses what that fetch found), never asks, and installs waiting commits only when
  `autoUpdate` is on. Run by hand, it always checks GitHub. Keep it small and apart from setup: it's how fixes arrive, so even a
  broken setup can be fixed by an update. For the same reason, the sync loads it only when it
  reaches the check, and an update.py that can't load or stops is a `PROBLEM` line, after which
  the sync still runs setup; each of the sync's other steps runs in a guard too, so an error in
  one is a `PROBLEM` line and the update check and setup still run; and when the code can't
  load at all, the entry points and `prepare.py` print a `PROBLEM` line with the commands that
  install a fix by hand (tests check all three).
- `prepare.py` runs the sync inside its own process, and the sync runs update's and setup's
  code there too. Setup runs as a process of its own right after an update installs, or when
  the shared modules changed while this sync waited for another one, so it gets one consistent
  version of the code throughout. So nothing in `internal/shared/` changes what the whole
  process shares, such as environment variables, the current folder, the import path, or sys's
  streams, outside an `if __name__ == "__main__":` block (a test checks). Their `main`
  functions return a number, and never raise or call `sys.exit`. And keep the name and
  arguments of what `prepare.py` calls,
  `main(argv)` in `sync.py`: the `prepare.py` running may be a generated copy older than the
  code on disk.

## Docs (README.md and docs/)

- The README is the front door: what dev-home is, what it needs, setup, a typical day, safety,
  and a table of every page under `docs/`. Everything else goes in `docs/`:
  - `docs/skills/`: one page per skill in `templates/skills/`, with the same name.
  - `docs/reference/`: facts to look up, such as what the scripts report and what setup changes.
  - `docs/guide/` (not made yet): how-to pages read start to finish, when one leaves the README.
  - `docs/development/`: for people and agents changing dev-home-tools. `decisions.md` records
    each design decision and each option set aside, with the reason and what would reopen it.
    Read it before reopening one. Findings from research on this project go there too, with the
    decision they led to.
- Each fact lives in one place, and other pages link to it.
- The README links to a skill's page in `docs/skills/`, never to its `SKILL.md`: the page is
  written for people, and the `SKILL.md` for agents. Each skill's page links to its `SKILL.md`,
  in its opening paragraph. Tests check both.
- Keep `docs/` ready to publish as a website: lowercase file names with hyphens, one `#` title
  per page, relative links between pages, and as few links out of `docs/` as possible, because
  those would break on a site, where each would have to become a full GitHub address.
- When you add, rename, or remove a page, update the README's table. A test checks it.

## Testing

- Before proposing a commit, run these four, from this repo's root:

  ```text
  uv run --directory internal/development pytest
  uv run --directory internal/development ruff check --config pyproject.toml ../..
  uv run --directory internal/development ruff format --check --config pyproject.toml ../..
  uv run --directory internal/development mypy
  ```

  uv installs the tools pinned in `internal/development/pyproject.toml` and `uv.lock`, for
  development only: people who use dev-home-tools never need them. The tools run from that
  folder, so their settings, `.venv`, and caches stay out of the root. Ruff looks for settings
  only in each file's own folder and the ones above it, so the ruff commands name them, and
  check the whole repo from its root, skipping what git ignores. The tests check the working
  tree, uncommitted changes included, and need no network or GitHub.
- pytest is the one entry point. It runs the tests in `internal/development/tests/`, which
  share `helpers.py`. `conftest.py` gives every test process the environment the scripts get
  in the sandbox, for the tests that run the scripts' code in that process, and checks after
  each worker's tests that nothing in the real profile points into a sandbox.
- The tests never run the scripts in this folder. They copy the repo into
  `internal/development/.test-sandbox/` (git ignores it), leaving out `internal/development/`
  and what's set up for this PC, and run the copy, whose `local-settings.json` sets
  `testHomeDir`, so every setup run from the copy uses a scratch profile instead of the real
  one.
- Test only through them. This folder may be someone's live setup: running its scripts against
  a test dev-home rewrites `internal/.generated/` and `local-settings.json`, which their real
  links depend on. Never add `testHomeDir` to a real `local-settings.json`.
- Run the skills' commands word for word from the sandbox's generated skills, as `helpers.py`
  does. It starts each with the test environment's Python, by its real path, in place of
  `internal/.python/python.exe`, because a virtual environment's `python.exe` can't run through
  a junction; that also lets coverage measure the scripts. One test runs a command unchanged.
  Adding `--cov` to the pytest command reports coverage, on demand and with no minimum.
- Add a test for every behavior you add or change. Fake only what needs a person or an outside
  service, such as a console answer, `gh`, Developer Mode, or another platform; git and the file
  system stay real. Use `monkeypatch` and small typed fakes first, and `unittest.mock` only with
  `autospec`, where recording calls saves real work.
- What needs a person is tested with a fake for them: setup's questions, a yes or no to a
  settings change, and creating dev-home with a faked gh (`test_setup_questions.py`, which runs
  setup's code in the test process from the sandbox's copy). What the tests can't reach, so it
  gets checked by hand: a real console's prompts, a real clone or repo creation on GitHub, and
  finding a Python through the registry, which a test profile skips. Say which of those a change
  affects.

## Style

- No em dashes in any file. Use a semicolon, colon, parentheses, a comma, or a new sentence.
- Plain language, for people who haven't seen the code.
- Comments describe the code as it is now, never what it used to do.
- Commit messages read `<area>: <what>`, for example `setup: link personal skills` or
  `handoff: check closed issues`. Commits here are signed.
