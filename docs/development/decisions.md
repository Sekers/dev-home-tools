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
Claude Code 2.1.284:

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
- **Always-on rules.** Neither tool loads instruction files from a plugin (Claude Code ignores a
  plugin's `CLAUDE.md`). Only a SessionStart hook could print them: capped at 10,000 characters
  in Claude Code and about 2,500 tokens by default in Codex, which also asks the user to trust
  the hook again after every change. The links setup makes today cost nothing.
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
That leaves the generated files with no note (`facts.ps1`, `prepare.ps1`, `filing-rules.md`, and
the handoff `template.md`, which can't have one because it's copied into every new handoff), and
anyone who ignores the note.

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
computer's name. Running two commands in one call also saves a round trip. Since then, every
skill command that syncs starts with one script anyway (see the next entry).

**Look again if:** a tool starts asking about joined commands whose parts are all pre-approved.

## Every skill command that syncs starts with one call: prepare.ps1

**Decision:** `templates/skill-scripts/prepare.ps1` runs `sync.ps1`, then `facts.ps1` with the
topics a skill names. It's the first command of every skill command that syncs. Skills still
commit through `sync.ps1 -Message`.

**The problem:** each command an agent runs costs a turn of the model, and turns cost more time
than the scripts do. A plain `/handoff` took five: `facts.ps1`, `sync.ps1`, reading the handoff,
a `git log` that agents added on their own to see what changed since the handoff's last check,
and the summary. Now it takes three.

**Why one script:** it's one literal command, with one pre-approval, that an agent can't split,
reorder, or send as two calls at once, and it works the same in every tool and on every
platform. The order matters: setup, which the sync runs, rewrites the generated `facts.ps1` when
its template has changed, so the facts come from the new copy, never from one being written. It
always exits 0, because a failing exit code makes a tool report the whole call as failed, and an
agent could then stop instead of following the skill's steps for each line.

**Why shared:** every skill command that syncs starts the same way, so this is the one place for
what would otherwise be copied into each skill, such as handling a tool that can't sync.

**Options set aside:**

- Each skill joining `sync.ps1; facts.ps1` in one line: it rests on each tool approving joined
  commands, and gives other skills nothing to build on.
- A switch on `sync.ps1` that also prints the facts, run inside sync's process: `facts.ps1`
  defines its own `Invoke-Git` and sets an environment variable, against the rules for code that
  runs there, and `sync.ps1` is for people too, while this is only for agents.
- Printing the handoff from the script as well, to save reading it: a long handoff passes the
  30,000 characters Claude Code shows of a command's output, and editing a file needs a real read
  of it anyway.

**Look again if:** a skill needs something at its start that one call can't give it.

## The skills don't run commands as they load

**Decision:** no skill uses Claude Code's `` !`command` `` lines, which run a command as the
skill loads and put its output in the skill's text.

**The option:** run `prepare.ps1` that way, saving one more turn per skill command in Claude
Code. Codex would get the line as text, and run the command itself.

**Why not:** when the command can't run cleanly, the whole skill aborts before the model sees
it, with a raw error and nothing to explain it. Tested on 2026-10-02 with Claude Code 2.1.284,
through `claude -p` and probe skills:

- It runs for a typed command and when the model starts the skill, again at each use, in the
  session's folder, and the model sees the output.
- A command that exits non-zero, or one no rule allows, aborts the skill.
- With the PowerShell tool on, as it is by default on Windows with a claude.ai account, a Claude
  Code that can't find Git Bash runs the command through the PowerShell tool, which refuses one that starts `pwsh`, and
  the skill aborts. That happened with `claude` started from a Git Bash terminal. With
  `shell: bash` in the frontmatter it aborts too, saying Git Bash wasn't found.
- A slow command holds the skill back until it finishes, and Claude Code's docs give it 2
  minutes.

Without it, each of those cases still works, with a prompt or a slow call. Knowledge lookups
couldn't use it either, since they never sync.

**Look again if:** Claude Code passes a failed command's output to the model instead of
aborting, or finds Git Bash however it was started. Since `prepare.ps1` always exits 0, each
skill would need only the one line.

## facts.ps1 finds the commit the handoff's State line names

**Decision:** the `newer-commits` topic of `facts.ps1` finds the commit hashes in the handoff's
State line that the project has, takes the one with the fewest commits after it, which is the
latest the update knew of, and counts both ways: `newer`, the commits this checkout has that it
doesn't, and `behind`, the ones it has that this checkout doesn't. The handoff skill's read
mentions newer commits, and says to pull when the checkout is behind. That's the common case
across PCs: work pushed from one, and not pulled yet on the other. A backticked hash this
checkout doesn't have at all gives `checked: missing`, with the same advice, since a commit the
update knew of is absent. Only a hash with letters and digits counts there, so a plain number
or a word such as `deadbee` doesn't raise it.

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

## The skill scripts write UTF-8 bytes

**Decision:** `facts.ps1` and `prepare.ps1` write each line as UTF-8 bytes straight to the output
stream, and read git's output as UTF-8, switching `[Console]::OutputEncoding` only around each
call and back again.

**The problem:** agents read a command's output as UTF-8, but PowerShell writes a script's
output, and reads a program's, in the console's code page. So an accented letter in a project's
name, a handoff's path, or a commit subject reached the agent as another character, and a
handoff path with one led nowhere.

**Why both halves:** tested with PowerShell 7.6 on Windows, with output redirected as agents run
it. Setting `[Console]::OutputEncoding` to UTF-8 does make PowerShell read git's output as
UTF-8, but its own output still came out in the console's code page. Writing the bytes to the
output stream directly is what reaches the agent intact. The setting goes back after each call,
because changing it can also change the code page of a console the script runs in.

**Look again if:** PowerShell writes redirected output as UTF-8 by itself.

## The tests are a plain script, not Pester

**Decision:** `internal/tests/Invoke-Tests.ps1` stays a plain PowerShell script.

**Why:** each group's checks are ordered steps in one sandbox, the sandbox's safety code would
stay custom anyway, and Pester 5 or later would be a new install (Windows ships 3.4).

**Look again if:** CI is added, setup's functions need unit tests, or the suite gets slow (try
a `-Group` parameter first).
