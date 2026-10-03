# dev-home-tools: guidance for AI agents

**What this repository is:** the public tooling for dev-home, a private repo that each person
keeps for AI-agent handoffs and a general knowledge base, shared across their PCs through GitHub,
for Claude Code and Codex. This repo holds the `handoff` and `knowledge` skills and the scripts
they share, the always-on operating rules, `setup.ps1`, `sync.ps1`, `update.ps1`, and the starter
files for a new private repo. It never holds anyone's handoffs, knowledge, or global rules.
README.md and `docs/` describe how people use it.

## The two repos

"dev-home" always means a person's private repo, and "dev-home-tools" always means this one.
Never leave it to the reader to guess which: name the repo whenever both could fit.

| What | dev-home-tools (this repo, public) | dev-home (each person's, private) |
| --- | --- | --- |
| Always-on rules | `templates/operating-rules/operating-rules.md`: the operating rules, the same for everyone | `global-rules/global-rules.md`: that person's global rules |
| Skills | `templates/skills/`: the `handoff` and `knowledge` skills. `templates/skill-scripts/`: the scripts they share | `skills/`: that person's own skills |
| `AGENTS.md`, `CLAUDE.md`, `README.md` | About dev-home-tools, and working on it | About that dev-home, and working in it |
| Only here | `setup.ps1`, `sync.ps1`, `update.ps1`, `templates/dev-home-starter/`, `internal/`, `docs/` | `handoffs/`, `knowledge/` |

- `templates/dev-home-starter/` holds a new dev-home's first files. Setup copies them in once,
  and after that they're the person's own: a change to the starter never reaches an existing
  dev-home.
- `internal/` is dev-home-tools' own machinery, which nobody runs directly: `internal/shared/`,
  which the three scripts load, and `internal/tests/`.
- Where a script goes depends on who runs it. The root holds only what a person may run by hand;
  agents run those too. A script that only agents run goes under `templates/`: in its skill's
  folder when one skill uses it, and in `templates/skill-scripts/` when skills share it.

## Privacy

- This repo is public, and its users keep private things in their own dev-home. Never put
  anyone's handoff or knowledge content, names, account or GitHub names, PC names, tenant
  details, or personal paths in any file, commit message, or issue here. The only exceptions
  are this repo's own address (`Sekers/dev-home-tools`, in the README's clone command) and the
  copyright line in LICENSE.
- Examples use made-up values: paths such as `C:/Users/you/dev-home` or
  `C:\Programming\dev-home`, and `example.com` for any domain.
- Before proposing a commit, read the whole diff for those.

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
  - `{{SKILL_DIR}}`: the skill's own folder under `.generated/skills/` (skills only).
  - `{{SKILL_SCRIPTS_DIR}}`: the shared scripts' folder, `.generated/skill-scripts/`.
- `templates/operating-rules/`, `templates/skills/`, and `templates/skill-scripts/` are filled in
  on every setup run and written to `.generated/`, at the same paths. The skills and rules there
  are what gets linked into the tools, and the skills run the shared scripts from there. The
  starter has no copy there, because setup fills it in only once (see "The two repos").
- A file and its folder keep the same name at every stage: template, generated copy, and link,
  such as `operating-rules/operating-rules.md`. The links in each Claude Code folder's `rules/`
  are the exception: nothing there says which repo a name belongs to, so each is named
  `dev-home-` plus the folder it points to.
- Pre-approvals in `allowed-tools` match the literal command text, so write every command with a
  placeholder where the path goes, never a variable or `~`. After setup fills it in, the command
  in the steps and the pre-approval match exactly.
- Never edit `.generated/` or `local-settings.json`. Setup rewrites both, and git ignores both.

## Skills (templates/skills/)

- Frontmatter uses only standard fields: `name`, `description`, and `allowed-tools`. The name
  matches the folder name.
- Refer to a skill's own files through `{{SKILL_DIR}}`, to a shared script through
  `{{SKILL_SCRIPTS_DIR}}`, and to anything else through `{{TOOLS_DIR}}` or `{{CONTENT_DIR}}`.
- Write steps in plain language, and write commands exactly as they will be run, with
  forward-slash paths, so they work in Git Bash, PowerShell, and Codex.
- Leave commands that publish outside dev-home, such as `gh issue create`, out of
  `allowed-tools`. Whether they ask first is each person's choice, in their own settings.
- Pre-approve a `pwsh` command only as `Bash(...)`, and have the skill tell Claude Code to run
  it with the Bash tool. Claude Code's PowerShell tool asks before running any command that
  starts another PowerShell, even one a `PowerShell(...)` rule matches exactly. Other commands,
  such as `gh issue view`, get both a `Bash(...)` and a `PowerShell(...)` pre-approval.
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

## Scripts the skills share (templates/skill-scripts/)

- These are scripts that only agents run, and that more than one skill may run. Skills point to
  the one generated copy; never copy a script into each skill's folder.
  `docs/development/decisions.md` says why, and why they aren't at the root or in `internal/`.
- One job per script, named for the job. `facts.ps1` reports facts about where a session is
  running, one topic at a time.
- `facts.ps1` only reports, and only from this PC: it changes nothing and never uses the network.
  That's what makes it safe to pre-approve, and a test searches it for both. Anything a skill
  needs done, rather than told, goes in a script of its own.
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

## setup.ps1, sync.ps1, and update.ps1

- ASCII only. All three require PowerShell 7.2 or later, and support Windows only for now.
- `internal/shared/` holds what the three share, one file per job, named for it: `git.ps1`
  (`Invoke-Git`, which retries while another git process holds a lock) and `output.ps1`
  (`Write-StatusLine`, which prints every status line in one format, and small text helpers).
  Each script dot-sources the files it uses when it starts, so after an update the next script
  to start gets the new copies. Put anything the scripts would otherwise each copy there. The
  files only define functions, and no script defines one with the same name (a test checks).
- Safe to re-run. setup.ps1 never overwrites or deletes anything except its own generated files,
  links whose target is gone, links it made to skills that no longer exist, and settings files
  the person said yes to changing. A settings change is shown as a diff first, waits for a typed
  yes, saves a dated backup, and is never offered for a file the script can't fully parse.
  sync.ps1 never stages, commits, or discards a file it wasn't given, and runs no destructive git
  command: no `add -A`, stash, `reset`, `checkout`, `clean`, or rebase.
- Never remove links with `Remove-Item -Recurse`; it follows junctions. Use `cmd /c rmdir`.
- Agents run setup.ps1 only with `-Quiet`, which never prompts: no elevation, no settings
  changes, and no creating repos. sync.ps1 runs it that way after every sync that doesn't commit,
  and after one that commits when it brought in commits from GitHub. Only a person runs it
  without `-Quiet`.
- update.ps1 pulls exactly the commit it showed the user, so nothing new can slip in between their
  yes and the pull.
- Everything about dev-home-tools updates happens in update.ps1, so what the user is told and
  what gets installed come from the same code. Every sync that doesn't commit runs
  `update.ps1 -Quiet`, which checks GitHub, never asks, and installs waiting commits only when
  `autoUpdate` is on. Keep update.ps1 small and apart from setup.ps1: it's how fixes arrive, so
  even a broken setup can be fixed by an update.
- sync.ps1 runs `update.ps1 -Quiet` inside its own PowerShell process, so no second one has to
  start. So update.ps1 and `internal/shared/` follow two rules, which tests check. They change
  nothing the whole process shares, such as environment variables, the current folder, or a
  static property like `[Console]::OutputEncoding`, because that would carry over into the rest
  of the sync. And they set every variable they read: pwsh -File keeps sync.ps1's
  top-level variables in the global scope, so a variable left unset would quietly pick up
  sync's. The `exit` in update.ps1 ends only update.ps1, and every `-Quiet` path ends with one,
  because sync reads its exit code.
- setup.ps1 runs in a process of its own, so it starts clean. It shares many variable names with
  sync.ps1, so running it inside sync's process would need the same checks first.

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

- Run `pwsh -NoProfile -File internal/tests/Invoke-Tests.ps1` before proposing a commit. It
  tests the working tree, uncommitted changes included, and needs no network or GitHub.
- It never runs the scripts in this folder. It copies the repo into `.test-sandbox/` (git
  ignores it) and runs the copy, whose `local-settings.json` sets `testHomeDir`, so every setup
  run from the copy uses a scratch profile instead of the real one.
- Test only through it. This folder may be someone's live setup: running its scripts against a
  test dev-home rewrites `.generated/` and `local-settings.json`, which their real links depend
  on. Never add `testHomeDir` to a real `local-settings.json`.
- Add a check to it for every behavior you add or change. It can't cover what needs a person:
  setup's first-run questions, cloning or creating dev-home with gh, and a yes to a settings
  change. Say which of those a change affects, so they get checked by hand.
- The tests stay a plain script, not Pester: `docs/development/decisions.md` says why, and when
  to look again.

## Style

- No em dashes in any file. Use a semicolon, colon, parentheses, a comma, or a new sentence.
- Plain language, for people who haven't seen the code.
- Comments describe the code as it is now, never what it used to do.
- Commit messages read `<area>: <what>`, for example `setup: link personal skills` or
  `handoff: check closed issues`. Commits here are signed.
