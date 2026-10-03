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
`.generated/`.

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

**The problem:** setup rewrites `.generated/` (and Codex's `AGENTS.md`) on every run without
checking for edits, so an edit made there is lost at the next sync, with no message. Each
skill's `SKILL.md` and the operating rules open with a note naming the template to change
instead, which agents see when the skill or rules load, and people see when they open the file.
That leaves the generated files with no note (`facts.ps1`, `filing-rules.md`, and the handoff
`template.md`, which can't have one because it's copied into every new handoff), and anyone who
ignores the note.

**Options set aside:** record what setup last wrote and, when a file differs, keep a copy and
report a `PROBLEM` (as chezmoi does); keep a `.bak` of the old file (as Ruler does); or make the
generated files read-only.

**Look again if:** an edit is ever actually lost, or plugins are looked at again (see above),
where a hook could block agents' edits under `.generated/`.

## Scripts the skills share are generated once, and skills point to them

**Decision:** a script that more than one skill may run, and that only agents run, lives in
`templates/skill-scripts/`. Setup generates one copy into `.generated/skill-scripts/`, and every
skill runs that copy. The first is `facts.ps1`, which reports facts about where a session is
running, one topic at a time.

**Why not a copy in each skill's folder:** most published skills are built that way, so that a
skill can be installed alone. These skills come with the toolkit, so that buys little here. One
path gives each command one text to pre-approve, where copies would give the same command a
different path in every skill, and a turned-off skill leaves nothing behind.

**Why not the root:** the root holds what a person may run by hand. A script there looks like
one of those.

**Why not `internal/`, or a folder of its own, run in place:** a half-finished edit to a script
that runs in place is live at once in every session on the PC. A generated script changes only
when setup runs, in the same run that rewrites the skill text that calls it, so the two files
are never out of step. A session that loaded the skill before that run still has the old text,
and stays that way until a new session starts. `templates/` is also where everything the tools
get from this repo already lives.

**Why one script with topics, not one that does everything:** `facts.ps1` is safe to pre-approve
because it only reports, and only from this PC. A script that also changed things would lose
that, so anything a skill needs done goes in a script of its own.

**Look again if:** the skills are shipped without the toolkit, as a plugin for example (see
above), where each would need the scripts bundled with it.

## The skills don't say to run each command in its own call

**Decision:** no such rule.

**The problem:** agents join the commands a skill gives them, such as `sync.ps1; facts.ps1`,
although the skill says to run them exactly as written. A joined call asks the user first when
any part of it isn't pre-approved.

**Why not:** a joined call whose parts are all pre-approved runs without asking (seen in Claude
Code 2.1.286), so joining isn't what causes a prompt: an unapproved part is. The fix for that is
a pre-approved way to get what the agent wanted, which is how `facts.ps1` came to report the
computer's name. Running two commands in one call also saves a round trip.

**Look again if:** a tool starts asking about joined commands whose parts are all pre-approved.

## The tests are a plain script, not Pester

**Decision:** `internal/tests/Invoke-Tests.ps1` stays a plain PowerShell script.

**Why:** each group's checks are ordered steps in one sandbox, the sandbox's safety code would
stay custom anyway, and Pester 5 or later would be a new install (Windows ships 3.4).

**Look again if:** CI is added, setup's functions need unit tests, or the suite gets slow (try
a `-Group` parameter first).
