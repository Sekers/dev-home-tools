# dev-home-tools: guidance for AI agents

**What this repository is:** the public tooling for dev-home, a private repo that each person
keeps for AI-agent handoffs and a general knowledge base, shared across their PCs through GitHub,
for Claude Code and Codex. This repo holds the `handoff` and `knowledge` skills, the always-on
core rules, `setup.ps1`, `sync.ps1`, and the starter files for a new private repo. It never holds
anyone's handoffs, knowledge, or personal rules. README.md describes how people use it.

## The two repos

This repo and each person's dev-home have folders and files with the same names. Before writing
about a path or a rule, check which repo it belongs to.

| What | dev-home-tools (this repo, public) | dev-home (each person's, private) |
| --- | --- | --- |
| `rules/` | `core.md`: the core rules, the same for everyone | `global.md`: that person's own rules |
| `skills/` | The `handoff` and `knowledge` skills, as templates | That person's own skills |
| `AGENTS.md`, `CLAUDE.md`, `README.md` | About dev-home-tools, and working on it | About that dev-home, and working in it |
| Only here | `setup.ps1`, `sync.ps1`, `update.ps1`, `starter/`, `tests/` | `handoffs/`, `knowledge/` |

- `starter/` holds a new dev-home's first files. Setup copies them in once, and after that
  they're the person's own: a change to `starter/` never reaches an existing dev-home.
- Whenever both repos come up, name the one you mean: "dev-home-tools" or "your dev-home". Never
  call the tooling "dev-home".

## Privacy

- This repo is public, and its users keep private things in their own dev-home. Never put
  anyone's handoff or knowledge content, names, account or GitHub names, PC names, tenant
  details, or personal paths in any file, commit message, or issue here. The only exceptions
  are this repo's own address (`Sekers/dev-home-tools`, in the README's clone command) and the
  copyright line in LICENSE.
- Examples use made-up values: paths such as `C:/Users/you/dev-home` or
  `C:\Programming\dev-home`, and `example.com` for any domain.
- Before proposing a commit, read the whole diff for those.

## Placeholders and generated files

- Every file under `skills/`, plus `rules/core.md`, is a template. Setup replaces these
  placeholders with forward-slash absolute paths and writes the results to `.generated/`, which
  is what gets linked into the tools:
  - `{{TOOLS_DIR}}`: this repo's folder on that PC.
  - `{{CONTENT_DIR}}`: that person's dev-home folder.
  - `{{SKILL_DIR}}`: the skill's own folder under `.generated/skills/` (skills only).
- Files under `starter/` use `{{TOOLS_DIR}}` and `{{CONTENT_DIR}}` too. Setup fills them in once,
  when it creates someone's dev-home, and after that the files are theirs.
- Pre-approvals in `allowed-tools` match the literal command text, so write every command with a
  placeholder where the path goes, never a variable or `~`. After setup fills it in, the command
  in the steps and the pre-approval match exactly.
- Never edit `.generated/` or `local-settings.json`. Setup rewrites both, and git ignores both.

## Skills (skills/)

- Frontmatter uses only standard fields: `name`, `description`, and `allowed-tools`. The name
  matches the folder name.
- Refer to a skill's own files through `{{SKILL_DIR}}`, and to anything else through
  `{{TOOLS_DIR}}` or `{{CONTENT_DIR}}`.
- Write steps in plain language, and write commands exactly as they will be run, with
  forward-slash paths, so they work in Git Bash, PowerShell, and Codex.
- Leave commands that publish outside dev-home, such as `gh issue create`, out of
  `allowed-tools`. Whether they ask first is each person's choice, in their own settings.
- Each skill stands on its own. Mention another skill only where that's part of how this one
  works.
- Some skills have similar rules. When you change a rule in one skill, check whether another skill
  has a similar rule that might need the same change. That it does is never a given: decide from
  how each skill works.
- After changing a skill, read the whole skill the way an agent meets it: top to bottom, each
  sentence taken literally, including every section that points to what changed. Look for
  anything an agent could misread or slip through: two rules that disagree, a question whose
  answer is unclear, a step the scripts can't do, or wording that only fits Claude Code.

## Always-on rules (rules/core.md)

- Keep the first heading, "Private repo: dev-home (rules loaded)". The handoff skill checks for
  it.
- Only rules the skills and scripts depend on belong here. Personal preferences go in each
  person's own `rules/global.md`, which loads along with this file and wins where they conflict.
- Claude Code loads both files through links in each Claude folder's `rules/`, such as
  `~/.claude/rules/`. Codex reads only one file, so setup writes `~/.codex/AGENTS.md` as the two
  joined. Keep this file short: it loads in every session.

## setup.ps1 and sync.ps1

- ASCII only. Both require PowerShell 7.2 or later, and support Windows only for now.
- Safe to re-run. setup.ps1 never overwrites or deletes anything except its own generated files,
  links whose target is gone, links it made to skills that no longer exist, and settings files
  the person said yes to changing. A settings change is shown as a diff first, waits for a typed
  yes, saves a dated backup, and is never offered for a file the script can't fully parse.
  sync.ps1 never stages, commits, or discards a file it wasn't given, and runs no destructive git
  command: no `add -A`, stash, `reset`, `checkout`, `clean`, or rebase.
- Never remove links with `Remove-Item -Recurse`; it follows junctions. Use `cmd /c rmdir`.
- Agents run setup.ps1 only with `-Quiet`, which never prompts: no elevation, no settings
  changes, and no creating repos. sync.ps1 runs it that way after every sync. Only a person runs
  it without `-Quiet`.

## Testing

- Run `pwsh -NoProfile -File tests/Invoke-Tests.ps1` before proposing a commit. It tests the
  working tree, uncommitted changes included, and needs no network or GitHub.
- It never runs the scripts in this folder. It copies the repo into `.test-sandbox/` (git
  ignores it) and runs the copy, whose `local-settings.json` sets `testHomeDir`, so every setup
  run from the copy uses a scratch profile instead of the real one.
- Test only through it. This folder may be someone's live setup: running its scripts against a
  test dev-home rewrites `.generated/` and `local-settings.json`, which their real links depend
  on. Never add `testHomeDir` to a real `local-settings.json`.
- Add a check to it for every behavior you add or change. It can't cover what needs a person:
  setup's first-run questions, cloning or creating dev-home with gh, and a yes to a settings
  change. Say which of those a change affects, so they get checked by hand.

## Style

- No em dashes in any file. Use a semicolon, colon, parentheses, a comma, or a new sentence.
- Plain language, for people who haven't seen the code.
- Comments describe the code as it is now, never what it used to do.
- Commit messages read `<area>: <what>`, for example `setup: link personal skills` or
  `handoff: check closed issues`. Commits here are signed.
