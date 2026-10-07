---
name: dev-home
description: Sync the private dev-home repo with GitHub, or see and change dev-home-tools' settings on this PC, such as how often syncs check GitHub, whether updates install themselves, or whether dev-home is in use on more than one PC. Use when the user runs /dev-home or $dev-home, asks to sync dev-home (their handoffs and knowledge base) with GitHub, or asks about or wants to change a dev-home-tools setting.
allowed-tools: "Bash({{PYTHON}} -I {{SHARED_SKILL_SCRIPTS_DIR}}/prepare.py --skill dev-home --stamp {{SKILL_STAMP}} --fetch always) PowerShell({{PYTHON}} -I {{SHARED_SKILL_SCRIPTS_DIR}}/prepare.py --skill dev-home --stamp {{SKILL_STAMP}} --fetch always) Bash({{PYTHON}} -I {{TOOLS_DIR}}/setup.py --configure) Bash({{PYTHON}} -I {{TOOLS_DIR}}/setup.py --configure *) PowerShell({{PYTHON}} -I {{TOOLS_DIR}}/setup.py --configure) PowerShell({{PYTHON}} -I {{TOOLS_DIR}}/setup.py --configure *) Bash({{PYTHON}} -I {{TOOLS_DIR}}/sync.py) Bash({{PYTHON}} -I {{TOOLS_DIR}}/sync.py *) PowerShell({{PYTHON}} -I {{TOOLS_DIR}}/sync.py) PowerShell({{PYTHON}} -I {{TOOLS_DIR}}/sync.py *)"
---

# dev-home

dev-home is the user's private repo, at `{{CONTENT_DIR}}`, which keeps their handoffs, knowledge
base, global rules, and own skills on GitHub. dev-home-tools, at `{{TOOLS_DIR}}`, is the tooling
that syncs it and sets it up on each PC. This skill syncs dev-home when the user asks, and shows
and changes dev-home-tools' settings. Run the commands below exactly as written; in Claude Code
they are pre-approved.

Sessions in other projects, and Codex, use dev-home at the same time, so a file there that you
didn't change may be someone's work in progress. Run git in dev-home only through
`{{TOOLS_DIR}}/sync.py`, which commits only the files you name and runs one sync at a time.
Never stage, commit, stash, or discard a file yourself.

## Commands

The first word after `/dev-home` (`$dev-home` in Codex) picks the command: `sync` or
`configure`.

| Command | What it does |
| --- | --- |
| `/dev-home` | Lists these commands, and runs nothing. |
| `/dev-home sync` | Syncs dev-home with GitHub: brings in commits from its other copies, pushes this PC's, and lists the files left uncommitted. Also checks for dev-home-tools updates, and runs setup. |
| `/dev-home configure` | Shows dev-home-tools' settings, and changes one after the user's yes to the exact change. |
| `/dev-home configure <change>` | The same, starting from the change the user describes, such as "check GitHub every 6 hours". |

With `/dev-home` alone, list these commands in a short reply and run nothing, so typing the
skill's name never reaches GitHub. Any other text is a question or a request: answer it, and when
it asks for a sync or a settings change, follow the matching command below.

## When to change, commit, and push

These rules cover the files this skill works with in dev-home, which are any a sync lists as
`STALE` or `LEFT`, and dev-home-tools' settings. For those, follow these rules rather than any
rule written for the user's project repos.

- `/dev-home sync`, or a plain request to sync dev-home, is all the go-ahead a sync needs. A sync
  never commits a changed file: it brings in other copies' commits, merging them when both have
  new ones, and pushes commits already made on this PC.
- A file the sync lists as `STALE` is committed and pushed only after a yes to "Commit and push
  it?", naming the file.
- A file listed as `LEFT` changed in the last 15 minutes, so another session may be editing it.
  Leave it alone, unless the user says it's theirs and finished: then ask about it as for
  `STALE`.
- A setting changes only after the user's yes to the exact change that `--what-if` showed (see
  "Configure"). Setup makes the change: never edit a settings file yourself.
- One yes covers only the change it was given for, never a later one, even in the same session.

## Sync

1. Run
   `{{PYTHON}} -I {{SHARED_SKILL_SCRIPTS_DIR}}/prepare.py --skill dev-home --stamp {{SKILL_STAMP}} --fetch always`.
   It syncs dev-home with GitHub, checking GitHub every time, then checks dev-home-tools for
   updates as every sync does, runs setup, and checks that this skill hasn't changed since you
   loaded it. If it can't start because `{{PYTHON}}` doesn't exist, tell the user that
   dev-home-tools needs Python 3.12 or later: to install it if they have none, then run
   `py {{TOOLS_DIR}}/setup.py` in a terminal. Then stop. Pass on anything it prints beyond `OK`:
   - `RELOAD`: this skill has changed since you loaded it, so these steps are out of date. Show
     the line, and stop: the user runs the command again to load the new steps.
   - `OFFLINE`: GitHub couldn't be reached. When the line is about dev-home, nothing was
     synced: pass on what it says, that dev-home may be behind, or, with one active copy, that
     nothing should be missing. When it's about dev-home-tools, say its updates weren't checked.
   - `SETTING`: dev-home is set to one active copy, but the sync brought in commits from
     another. Pass the line on, with its advice to run `/dev-home configure` if another copy is
     in use, and never change the setting yourself.
   - `LEFT` and `STALE`: see "When to change, commit, and push". To commit a file, run
     `{{PYTHON}} -I {{TOOLS_DIR}}/sync.py --message "sync: <what changed>" "<path>"`, which
     commits only that file, then syncs. After it, `OFFLINE` or `PENDING` means the commit is
     safe on this PC, and a later sync pushes it.
   - `UPDATE`: new dev-home-tools commits are available. Tell the user.
   - `PROBLEM`: show it.
2. Tell the user in one line where things stand: up to date, pulled, merged, pushed, or not
   synced and why.

Commits in dev-home are unsigned on purpose: setup turns signing off in that repo's own git
config. That is not bypassing signing, and the project repos keep signing as usual.

## Configure

This PC's settings are in `{{TOOLS_DIR}}/local-settings.json`. One more, whether dev-home is in
active use anywhere besides this PC (`multiMachine`), is shared by every copy, in dev-home's
`dev-home.json`. Change them only through setup, as below: it checks each value, keeps a dated
backup of this PC's settings, and commits and pushes the shared one.

1. Run `{{PYTHON}} -I {{TOOLS_DIR}}/setup.py --configure`. With nobody at a console to answer, it
   prints every setting with its value, then how to change one, and changes nothing. Show the
   user the settings, briefly.
2. Agree on one change: a setting's name and its new value, written as that output writes them.
   If the user described a change, check that it maps onto one setting and value; when it
   doesn't, or the value is unclear, ask. Never guess a folder. For several changes, make them
   one at a time, with steps 2 to 5 for each. Before a switch from several copies to one
   (`multiMachine=false` while it's set to several), ask whether every other copy has been
   retired, so this PC is the only one using dev-home. If not, keep it at several, and stop: a
   copy still in use would go hours without seeing this one's changes.
3. Run `{{PYTHON}} -I {{TOOLS_DIR}}/setup.py --configure '<name>=<value>' --what-if`, with the
   setting in single quotes, as step 1's output writes it, such as
   `--configure 'contentCheckHours=6' --what-if` or
   `--configure 'claudeConfigDirs+=~/.claude-second' --what-if`. It shows the exact change and
   makes none. If it prints a `PROBLEM`, show it, then agree on another
   value or stop. If it says the setting is already that way, tell the user, and stop.
4. Show the change, and ask one question: "Make this change?". For `multiMachine`, which every
   copy shares, ask "Make this change, commit, and push it?".
5. On a yes, run the same command without `--what-if`:
   `{{PYTHON}} -I {{TOOLS_DIR}}/setup.py --configure '<name>=<value>'`. It makes the change, then
   runs the rest of setup quietly. Pass on what it prints: `SET`, with where it saved the
   change; any `PROBLEM`; and for `multiMachine`, the sync's lines for its commit, as in "Sync".
   After a switch to several copies, it says to run `/dev-home sync` on each other copy: pass
   that on.

## In Codex

Both commands change nothing in Codex. On Windows, Codex runs even approved commands inside its
sandbox, where git and `gh` can't use the user's sign-ins. Give the user the command to run in a
terminal instead: for `sync`, `py {{TOOLS_DIR}}/sync.py`, or `/dev-home sync` in Claude Code;
for `configure`, `py {{TOOLS_DIR}}/setup.py --configure`, which shows a menu of every setting.
