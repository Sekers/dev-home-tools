# dev-home-tools

**dev-home** is a home base for working with AI coding agents (Claude Code and Codex): a private
GitHub repo of your own, with a copy on each of your PCs, holding what your agents should have
in every session. That's your own rules, your own skills, and anything those skills keep for
you.

**dev-home-tools**, this repo, is the public tooling that makes dev-home work:

- **Setup.** Its `setup.py` creates your dev-home the first time you run it, and clones it on
  your other PCs. On each PC, it connects dev-home to Claude Code and Codex, so every session
  loads your rules and skills.
- **Sync.** It keeps dev-home in sync with its online copy, so a change made on one PC reaches
  the others.
  - Setup puts dev-home on GitHub for now (just dev-home: your project repos can be hosted
    anywhere). Automated setup for GitLab, Bitbucket, and Azure DevOps is coming.
- **Privacy.** It tells every session never to copy dev-home into your project repos, or even
  mention it there, so your projects can stay public.
- **Skills.** It comes with ready-made skills, listed below, and sets up any you add to your own
  dev-home.

This repo never holds anyone's own content: that stays in each person's private dev-home.

**What's a skill?** It's like a custom command for your agent: a folder of instructions that
teaches it one task. Type its name to run it, such as `/handoff` in Claude Code or `$handoff` in
Codex, or just ask in your own words, and the agent uses the matching skill on its own. Both
tools support skills in the shared [Agent Skills](https://agentskills.io) format. To learn more,
see skills in the [Claude Code docs](https://code.claude.com/docs/en/skills) and the
[Codex docs](https://learn.chatgpt.com/docs/build-skills).

**Skills included:**

| Skill | What it does |
| --- | --- |
| [`handoff`](docs/skills/handoff.md) | Keeps one private note per project in your dev-home: what's next, what's in progress, what's waiting on you or on others, and what's left to do. Start a session with `/handoff`, and the agent picks up where the last one stopped, on any of your PCs. |
| [`knowledge`](docs/skills/knowledge.md) | Keeps your own knowledge base in your dev-home: general things you've learned about languages, tools, and AI agents, so no session has to work them out twice. Agents check it before researching or testing a general question, even partway through other work. |
| [`dev-home`](docs/skills/dev-home.md) | Syncs your dev-home with GitHub when you ask, lists the skills it sets up, and shows and changes dev-home-tools' settings, such as how often syncs check GitHub. |

Works with Claude Code, Codex, or both. Windows only, for now. To start, see
[Set up a PC](#set-up-a-pc).

## Requirements

| What | Why | Install |
| --- | --- | --- |
| Python 3.12 or later | Runs setup, the sync, updates, and the scripts the skills use. Only Python itself: nothing else to install. | The Python install manager: `winget install 9NQ7512CXL7T -e --accept-package-agreements --disable-interactivity`, then `py install 3.14` (or the latest version). |
| Git 2.31 or later | Every sync with GitHub. | `winget install --id Git.Git --source winget` |
| GitHub CLI (`gh`) | Creates or clones your dev-home on GitHub, and files issues for `/handoff issue`. | `winget install --id GitHub.cli --source winget` |
| Claude Code, Codex, or both | The agents the skills and rules are for. | Each tool's own installer. |

Open a new terminal window after installing, so the tools are on the PATH. Nothing here needs
admin rights. You start setup with the install manager's `py`, and after that the skills find
Python on their own (see [What setup changes](docs/reference/setup-changes.md)).

## Set up a PC

You clone this repo yourself. Setup then creates your dev-home on your first PC, or clones it on
later ones. Use a normal terminal window, not an administrator one.

### 1. Before setup, once per PC

1. Sign in to GitHub: `gh auth login`. Choose HTTPS, and answer yes when it asks to authenticate
   Git with your GitHub credentials. Then git can pull and push without asking, even when an
   agent runs a sync. Signed in earlier without that? Run `gh auth setup-git`.
2. Make sure git knows who you are, because the scripts commit. If git already commits on this
   PC, keep what you have. Otherwise, set at least a name and email:

   ```powershell
   git config --global user.name "Your Name"
   git config --global user.email "you@example.com"
   ```

   - To keep your email address private, use your GitHub no-reply address instead, such as
     `12345678+you@users.noreply.github.com`. GitHub shows yours under Settings > Emails.
   - If you sign your commits, leave that on. Setup turns signing off only inside dev-home, so
     a commit there never stops in the middle of a sync to ask for your signing passphrase. Your
     project repos keep signing as usual.

3. Start Claude Code once, and Codex if you use it, so their folders (`~\.claude`, `~\.codex`)
   exist. Setup skips Codex when `~\.codex` is missing.

### 2. Clone this repo

Clone it into a folder near the root of a drive, where you keep your programming work, such as
`C:\Programming`. Avoid your Documents folder, which is often synced by OneDrive, and OneDrive
can corrupt a git repo. The full path can't have spaces or other characters that need quoting
(letters, digits, `.`, `_`, `-`, and `@` are fine), because setup writes it into commands as it
is. If you use a [Dev Drive](https://learn.microsoft.com/windows/dev-drive/), it's an even
better place, such as `D:\Programming`.

```powershell
gh repo clone Sekers/dev-home-tools C:\Programming\dev-home-tools
```

Cloning your own fork instead? Updates then come from it. See
[Where updates come from](docs/reference/scripts.md#where-updates-come-from) to change that.

### 3. Run setup

```powershell
py C:\Programming\dev-home-tools\setup.py
```

To see what it would change first, add `--what-if`. It still asks its questions, but changes
nothing.

The first run asks these, and a later run asks any whose answer isn't saved yet:

| Question | What to answer |
| --- | --- |
| Your dev-home folder | Where your dev-home is, or should go. Press Enter for the suggestion: a `dev-home` folder next to this one, such as `C:\Programming\dev-home`. The same rules for the path apply. A folder that already has files in it must be a dev-home: setup checks for the files every dev-home starts with (`global-rules\global-rules.md` and `knowledge\README.md`), and asks again if they're missing, so it never changes a project's repo by mistake. |
| Pull updates automatically? | `y` to install new versions of this repo as soon as a sync finds them, or Enter for no: you're told about them and install them yourself. See [Updates](docs/reference/scripts.md#updates). |
| Also set up `~\.claude-<name>`? | Asked once for each extra Claude Code folder it finds, one per Claude account you run with `CLAUDE_CONFIG_DIR`, including one made after your first run. `y` sets that account up too, and `n` is kept, so it isn't asked again. When a quiet run finds a folder it hasn't asked about, the agent tells you: run setup in a terminal to answer. |
| Is dev-home in active use anywhere besides this PC? | Asked once, for a dev-home with no answer yet. After a clone of one set to a single copy, it's asked as "Will another copy stay in use alongside this one?" There's no default: type `y` if another PC, virtual machine, or cloud session uses it too, and each command then checks GitHub first; or `n` if this PC is the only one, such as one replacing a PC you've retired, and syncs then check GitHub only every few hours. Setup shows the change, and after a `y` to saving it, commits and pushes `dev-home.json`, so every copy agrees. |
| Clone your existing dev-home (c), create a new private one (n), or stop (s)? | Only when the dev-home folder doesn't exist yet. On your first PC, `n` creates a private repo on GitHub from the files in `templates/dev-home-starter/`. On every later PC, `c` clones it. Either way, it then asks for the repo's name; Enter accepts `dev-home`. |

Setup can create or clone dev-home only on GitHub for now; automated setup for GitLab,
Bitbucket, and Azure DevOps is coming. If your dev-home is already on one of those, or on your
own git server, clone it into your dev-home folder yourself before running setup. Setup then
uses it as it is, and syncing works the same as with GitHub.

This limit applies only to where dev-home itself is hosted. Your project repos can be anywhere,
or not hosted at all, and the skills work with them the same way. The one exception is filing a
handoff item as an issue, which needs the project on GitHub.

Then it links everything and checks Claude Code's and Codex's settings (see
[What setup changes](docs/reference/setup-changes.md) for what and why). When a setting is
missing, it shows the exact lines it would change and asks first. On a `y`, it saves a dated
backup of the file, such as `settings.json.bak-20260926-101500`, before writing. It never edits a
file it can't fully read, such as a `settings.json` with comments, or a read-only one; it prints
what to add by hand instead.

### 4. Restart, and check

Restart Claude Code and Codex, so they load the skills and rules. Run setup again, and repeat
until it ends with "All checks passed." Then you can delete the backups.

Syncs also run setup quietly, so changes to the skills, and skills you add on another PC, reach
this one. The one exception is a skill you've just created on this PC: it's linked at the next
`/handoff`, or right away when you run setup with `--quiet` (see
[Your own rules and skills](#your-own-rules-and-skills)).

Your answers are saved in `local-settings.json` in your dev-home-tools folder, next to
`setup.py`. To change one later, run setup with `--configure`:

```powershell
py C:\Programming\dev-home-tools\setup.py --configure
```

It shows every setting with its value. Type a setting's number to change it, `a` to go through
them all, or press Enter to finish; each question has your current answer as its default. Setup
keeps a dated backup of the file before it saves a change.

You can also edit the file and run setup again: `autoUpdate` is `true` or `false`;
`claudeConfigDirs` lists the extra Claude Code folders to set up, such as `"~/.claude-second"`;
`declinedClaudeConfigDirs` lists the ones you said no to, and taking a folder out of it makes
setup ask again; and `updateCheckHours` and `contentCheckHours` say how often a sync checks
GitHub for dev-home-tools updates (24 hours unless set) and for dev-home's changes (12 hours
unless set, when one copy is in active use, and for a plain `/knowledge`), where 0 means every
time. To use a different dev-home folder, run setup with `--content-dir <folder>`.

## Day to day

Run the skills in any project, in as many sessions at once as you like. Type one of a skill's
commands, which its page lists (see [Documentation](#documentation)), or ask in plain words and
the agent uses the matching skill. In Codex, type `$` instead of `/`, such as `$handoff`.

A typical day with the included skills:

1. In a project, run `/handoff`. The agent syncs your dev-home with GitHub, reads the project's
   handoff, and tells you what's next. For a project with no handoff yet, it offers to create
   one.
2. Work as usual. When you learn something worth keeping for every project, the agent may offer
   to add it to your knowledge base.
3. Before you stop, run `/handoff update`. The agent writes down where things stand, and saves
   it to GitHub so your other PCs get it.
4. Next time, on this PC or another one, `/handoff` picks up from there.

## Your own rules and skills

- **Rules.** Every session, in both tools and on every PC, loads two sets of always-on rules:
  - **Your global rules**, in `global-rules/global-rules.md` in your dev-home: your own
    preferences for every project. The file starts as the empty template from
    `templates/dev-home-starter/`, and after that it's yours to edit.
  - **The operating rules**, which come with dev-home-tools, in
    [`templates/operating-rules/operating-rules.md`](templates/operating-rules/operating-rules.md):
    how every session works with your dev-home, which the skills and scripts depend on. They're
    the same for everyone, and updates to dev-home-tools change them.

  Your global rules win where the two conflict, because the operating rules say so. Keep yours
  short: every line costs tokens in every session.
  - **How they load.** Setup hooks both into each tool's standard place for always-on
    instructions: Claude Code's
    [user-level rules](https://code.claude.com/docs/en/memory#user-level-rules) folder, as the
    links `dev-home-global-rules` and `dev-home-operating-rules`, and Codex's
    [global `AGENTS.md`](https://learn.chatgpt.com/docs/agent-configuration/agents-md), joined
    into one file.
  - **Already using `~\.claude\CLAUDE.md`?** It keeps loading in Claude Code, alongside these
    rules, and setup never touches it. But only Claude Code reads it, and only for that account
    on that PC. Move anything you want everywhere into your global rules, and take it out of
    `CLAUDE.md` so Claude doesn't read it twice.
  - **Already have your own `~\.codex\AGENTS.md`?** Setup needs that file for the joined rules,
    so it leaves yours alone and reports it. Move what you want to keep into your global rules,
    delete the file, and run setup again.
- **Skills.** Create `skills/<name>/SKILL.md` in your dev-home, with standard frontmatter only:
  `name` (the same as the folder), `description`, and optionally `allowed-tools`. Run
  `py C:\Programming\dev-home-tools\setup.py --quiet` to link it, and commit it (ask an agent,
  or wait for the next `/handoff` to offer). Your other PCs link it at their next
  sync. A skill can't share a name with one in this repo.

## What's in your dev-home

| Path | What it is |
| --- | --- |
| `handoffs/` | One handoff per project, filed by where the project is hosted (see [Handoffs](docs/skills/handoff.md#where-handoffs-are-kept)). |
| `knowledge/` | Your knowledge base. `knowledge/README.md` is its index. |
| `global-rules/global-rules.md` | Your global rules: your own preferences for every project, loaded in every session. |
| `skills/` | Skills of your own, if you add any. |
| `AGENTS.md`, `README.md` | Notes on working in dev-home itself, for agents and for you. |
| `.drafts/` | Scratch space for text that leaves dev-home, such as GitHub issue bodies. Git ignores it. |

Setup creates it from the files in this repo's `templates/dev-home-starter/` folder. After that,
its files are yours: updates to dev-home-tools never change them.

## Documentation

Everything beyond getting started is in the `docs/` folder:

| Section | Page | What's in it |
| --- | --- | --- |
| Skills | [Handoffs](docs/skills/handoff.md) | Every `/handoff` command, with examples: when a change is committed and pushed, how issues are filed, and where handoffs are kept. |
| Skills | [Knowledge base](docs/skills/knowledge.md) | Every `/knowledge` command, and when agents check the knowledge base or offer to add to it. |
| Skills | [dev-home](docs/skills/dev-home.md) | `/dev-home sync`, `configure`, and `skills`: syncing when you ask, changing a setting, and listing your skills. |
| Reference | [The scripts](docs/reference/scripts.md) | `setup.py`, `sync.py`, and `update.py`: when each one runs, what their status words mean, how updates are installed, and where they come from. |
| Reference | [What setup changes on your PC](docs/reference/setup-changes.md) | Every link, file, and setting that setup adds, why, and how to remove it all. |
| Development | [Design decisions](docs/development/decisions.md) | For people changing dev-home-tools: decisions made and options set aside, with the reasons. |

## Safety and privacy

- **Your project repos are treated as public.** The operating rules tell agents never to quote
  dev-home, paraphrase its notes, or mention that it exists in a project's files, commits, PRs,
  or issues. The one way handoff content reaches a project is an issue you approve word for word.
- **No secrets in dev-home:** no credentials, tenant or account IDs, or personal information
  about anyone else. Note where a secret is kept, never its value.
- **`sync.py` commits only what it's given.** Several sessions and PCs share dev-home, so any
  other changed file may be someone's work in progress. It never stages, commits, stashes,
  resets, or discards those. It runs one sync at a time, undoes a merge that conflicts, and never
  deletes a git lock file.
- **`setup.py` replaces only its own work:** its generated files, links whose target is gone,
  and links it made to skills that no longer exist. Anything else in its way is reported, not
  changed. Settings changes are shown first, need your yes, and keep a backup.
- **Tooling updates wait for you** unless you turn on `autoUpdate`, because whoever controls this
  repo on GitHub controls code that runs on your PC.
- **Never run `Remove-Item -Recurse`** on `~\.claude`, `~\.claude-*`, or `~\.agents`. It follows
  the links into your dev-home and deletes what's there. Remove a single link with
  `cmd /c rmdir <link>`.
- **Edit your global rules in dev-home,** in `global-rules/global-rules.md`, never in
  `~\.codex\AGENTS.md`, which setup rewrites.

## Troubleshooting

- **Setup ends with "problem(s) to fix".** Each `PROBLEM` line says what to do. Fix those, then
  run setup again.
- **`/handoff` says the operating rules aren't loaded.** Restart the agent. If it still says so,
  run setup and read its output. In the Claude desktop app's Cowork sessions, Claude Code skips
  rule folders linked from outside the session's folder, so the rules may not load there.
- **A skill seems to be missing.** Run setup with `--quiet`, then restart the agent.
- **A skill says dev-home-tools needs Python.** Install Python 3.12 or later (see
  [Requirements](#requirements)), then run setup again.
- **A sync says it stopped, with `git -C ... pull --ff-only` in the line.** dev-home-tools'
  own code couldn't load or run, so it can't check for updates, and a fix can't arrive by
  itself. Run the two commands the line gives: they install any update by hand, then run setup.
- **A skill says it has changed since the session loaded it.** An update changed the skill's
  steps. Type its command again, such as `/handoff`, to load the new ones; you don't need a new
  session.
- **Setup reports a dev-home repo with no commits.** A setup run stopped partway through
  creating it, for example because git didn't know your name yet. If that folder holds nothing
  you need, delete it, fix the cause, and run setup again.

## Working on dev-home-tools

| Path | What it is |
| --- | --- |
| `setup.py`, `sync.py`, `update.py` | The scripts (see [The scripts](docs/reference/scripts.md)): short entry points that load their code from `internal/shared/`. |
| `templates/` | Everything setup fills in with each PC's paths. |
| `templates/operating-rules/` | The operating rules every session loads, along with your global rules. Filled in on every setup run, into `internal/.generated/`. |
| `templates/skills/` | The skills, one folder each. Filled in on every setup run, into `internal/.generated/`. |
| `templates/shared-skill-scripts/` | Python scripts that the skills share and only agents run. Filled in on every setup run, into `internal/.generated/`. |
| `templates/dev-home-starter/` | The files a brand-new dev-home starts with. Filled in once, when setup creates it. |
| `internal/` | dev-home-tools' own machinery, which nobody runs directly. |
| `internal/shared/` | The code the scripts load, one file per job: `setup.py`, `sync.py`, and `update.py`, and the modules they share, such as `git.py` and `output.py`. The skills' `prepare.py` loads it too. |
| `internal/development/` | Only for changing dev-home-tools: the development tools' settings (`pyproject.toml`, `uv.lock`) and the tests (`tests/`, run with pytest). People who only use dev-home-tools never need it. |
| `docs/` | Everything this README leaves out (see [Documentation](#documentation)). |

[AGENTS.md](AGENTS.md) has the rules for changing this repo, for people and agents alike, and
[Design decisions](docs/development/decisions.md) says why it works the way it does.

Changing dev-home-tools takes [uv](https://docs.astral.sh/uv/), which installs the pinned
development tools (pytest, ruff, and mypy) the first time you run them. Before committing, run
these from this folder:

```powershell
uv run --directory internal/development pytest
uv run --directory internal/development ruff check --config pyproject.toml ../..
uv run --directory internal/development ruff format --check --config pyproject.toml ../..
uv run --directory internal/development mypy
```

The tools run from `internal/development/`, so their environment and caches stay there. The
tests check the working tree in throwaway copies under `internal/development/.test-sandbox/`,
never your real profile or dev-home, and need no network. Never point this folder's scripts at
a test dev-home: they would rewrite the files your real links depend on.

## License

MIT. See [LICENSE](LICENSE).
