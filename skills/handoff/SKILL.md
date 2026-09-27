---
name: handoff
description: Read or update this project's private session handoff (current state, next up, to-dos, bugs, traps), kept in the private dev-home repo, and file handoff items as GitHub issues when asked. Use when the user runs /handoff or $handoff, asks where things stand or where we left off, asks to update the handoff or change what's next up, or asks to file a handoff item as a GitHub issue.
allowed-tools: "Bash(pwsh -NoProfile -File {{SKILL_DIR}}/locate.ps1) Bash(gh label list *) Bash(gh issue list *) Bash(gh issue view *) Bash(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1) Bash(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 *) PowerShell(pwsh -NoProfile -File {{SKILL_DIR}}/locate.ps1) PowerShell(gh label list *) PowerShell(gh issue list *) PowerShell(gh issue view *) PowerShell(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1) PowerShell(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 *)"
---

# Handoff

A handoff is a private note, one per project, of where work stands: what's next up, work in
progress, settled decisions, to-dos, bugs, and traps. Handoffs live in the user's private repo,
dev-home, at `{{CONTENT_DIR}}`, never in the project itself. Run the commands below exactly as
written. In Claude Code they are pre-approved, except `gh issue create`: whether that one asks
first depends on the user's own permission settings.

Sessions in other projects, and Codex, use dev-home at the same time, so a file there that you
didn't change may be someone's work in progress. Run git in dev-home only through
`{{TOOLS_DIR}}/sync.ps1`, which commits only the files you name and runs one sync at a time.
Never stage, commit, stash, or discard a file yourself.

## Commands

The first word after `/handoff` (`$handoff` in Codex) picks the command: `update`, `next`, or
`issue`. Any other text is a question or request about the handoff. When the user asks in plain
words instead, such as "update the handoff", use the command that matches.

| Command | What it does |
| --- | --- |
| `/handoff` | Summarizes the handoff, starting with Next up. |
| `/handoff <question>` | The same, then answers the question. |
| `/handoff update` | Full update: brings the whole handoff up to date. If Next up looks done, asks before removing it. |
| `/handoff update <text>` | The same full update, with the user's text worked in. The text can also set, add to, or clear Next up. |
| `/handoff next` | Shows Next up. |
| `/handoff next <text>` | Replaces Next up with the text. Nothing else changes. |
| `/handoff next clear` | Removes Next up. |
| `/handoff issue` | Lists the items that could become GitHub issues. |
| `/handoff issue <item>` | Files that item as a GitHub issue, then links to it from the handoff. |

Change the handoff only when the user asked for a change: through `update`, `next`, or `issue`,
or by creating it (see "Find this project's handoff"). When a request could be a read or a
change, such as `/handoff next steps?`, treat it as a read and ask.

## Find this project's handoff

1. In the project, run `pwsh -NoProfile -File {{SKILL_DIR}}/locate.ps1`. It reads the
   project's address from its git config, without the network, and prints four lines. The steps
   below use them by name:
   - `service`: where the project is hosted: `github`, `gitlab`, `bitbucket`, `azure-devops`,
     `other` for anywhere else, or `local` for a project with no remote.
   - `name`: the project's name, such as `you/tool`. For `other` and `local`, it's the folder
     name plus the start of the project's first commit, such as `tools-3f9c2ab`.
   - `handoff`: the handoff's path in dev-home, such as `handoffs/github/you/tool/HANDOFF.md`.
   - `draft`: where a GitHub issue draft goes.

   If it prints an error instead, show the error and stop: without the script's answer, there's
   no telling which handoff is this project's.
2. The handoff is `{{CONTENT_DIR}}/<handoff>`. Check that it exists only after Read step 2's
   sync, so a handoff made on another PC has arrived.
3. If that file doesn't exist, list every `HANDOFF.md` under `{{CONTENT_DIR}}/handoffs/` and ask
   whether one of them is this project under an old name or address. On a yes, move it to
   `<handoff>`, then run the command below, where `<old path>` is where it was, relative to
   dev-home:
   `pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 -Message "handoff: <name>" "<old path>" "<handoff>"`.
   If none is, offer to create one from `{{SKILL_DIR}}/template.md`. On a yes, create it and
   commit it as in "Changing the handoff".

## Read (the default)

1. If your instructions don't include the heading "Private repo: dev-home (rules loaded)", tell
   the user that the always-on dev-home rules aren't loaded, then continue.
2. Run `pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1`. It syncs with GitHub, then runs setup.
   Pass on anything it prints beyond `OK`:
   - `OFFLINE`: say the handoff may be stale, and continue.
   - `LEFT`: leave the file alone. Another session may be editing it.
   - `STALE`: nobody has touched the file for 15 minutes. Ask whether to commit it. On a yes, run
     `pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 -Message "sync: <what changed>" "<path>"`.
   - `UPDATE`: new dev-home-tools commits are available. Tell the user, and continue.
   - `PROBLEM`: show it, say the handoff may be behind, and continue.
3. Find this project's handoff (see above), read it, and summarize where things stand. Start
   with Next up, as written, if there is one. If the user asked a question, answer it.

## Changing the handoff

`update`, `next`, and `issue` all change the handoff, and all of them:

1. Start with Read steps 1 and 2.
2. Read the handoff again right before editing it, and keep any change another session made
   since you last read it: a worktree of this project shares this handoff, and a sync can bring
   in another PC's version.
3. After editing, check the handoff for anything rule 7 forbids, and take it out.
4. Run
   `pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 -Message "handoff: <name>" "<handoff>"`.
   It commits only this handoff, then syncs.
   - `OFFLINE` or `PENDING`: the commit is safe on this PC, and a later sync pushes it.
   - `PROBLEM`: stop and show it. The handoff is safe on this PC.

Commits in dev-home are unsigned on purpose: setup turns signing off in that repo's own git
config, because agents commit there unattended. That is not bypassing signing, and the project
repos keep signing as usual.

## Update

Follow "Changing the handoff". While updating:

- Go through every section by the rules below: keep what's still true word for word, change
  what changed, and remove what's finished. Rewording unchanged text makes it drift, and makes
  merges between PCs more likely to conflict. Set the "State as of" line to what you actually
  checked this session; if you checked nothing, leave it.
- Next up: if the user's text says what to do with it, do that. Otherwise, if this session
  finished all of it, ask "Next up looks done: remove it?" before committing, and remove it only
  on a yes. If this session finished part of it, ask the same about that part. With no answer,
  leave it as it is.
- Text after `update` is the user's instructions for this update, in any words: a decision, a
  new bug, an item to drop, what's next up, and so on. Put each part where it fits, and
  afterwards say where each part went. If a part is unclear, or conflicts with what you found
  this session, ask before committing.
- For each item that links to a GitHub issue, run
  `gh issue view <number> --repo <owner>/<repo> --json state`, with the number and repo from the
  link. If the issue is closed, remove the item like any finished item, and say which ones you
  removed. If `gh` fails, keep the links and say they weren't checked.

After committing:

1. Offer a knowledge candidate only if one qualifies (see the knowledge skill); most sessions
   have none. Add none without a yes.
2. Offer issue candidates only if any qualify (see "Issue candidates"); most updates have none.
   File none without a yes.

## Next up

Next up is what the user wants the next session to start with. It's the section directly under
the "State as of" line, so it's the first thing anyone reads. Only the user changes it: through
`next`, the text of an `update`, or a yes when an update asks to remove finished work. Never
add, change, or remove it on your own judgment.

- `/handoff next`: run Read steps 1 and 2, then show Next up as written, or say there is none.
  Change nothing.
- `/handoff next <text>`: replace Next up with the text. If the text says to add to it, such as
  "also push the wiki", keep what's there and add it. Keep the user's meaning; you may tighten
  the wording and point to related items. Point to them by name, not number, because numbers
  change when items are removed. Say what you replaced.
- `/handoff next clear`: remove the whole section, or say there is none and change nothing.
  This applies only when nothing follows `clear`: `/handoff next clear the old wiki pages` sets
  Next up to that text.

Setting or clearing Next up follows "Changing the handoff", changes nothing else, and leaves the
"State as of" line alone, because nothing else was checked.

## GitHub issues

`/handoff issue <item>` files a handoff item as an issue in the project's GitHub repo: a bug, a
feature, a docs task, a design question, or anything else. Name the item by section and number,
such as `Bugs 1`, or describe it. Text that isn't in the handoff yet works too. If more than one
item matches, ask which. File one issue per item unless the user asks to combine them. Treat the
repo as public even if it isn't.

It follows "Changing the handoff", with these steps before the edit:

1. Find the repo, `<owner>/<repo>` below: it's `<name>`, unless the user named another repo.
   Filing issues works only on GitHub for now, so if `service` isn't `github`, say that and
   stop. If `gh` is missing or not signed in, stop and say so.
2. Look for an existing issue:
   `gh issue list --repo <owner>/<repo> --state all --search "<a few key words>"`. If one
   matches, show it and ask whether to link to it instead of filing a new one.
3. Draft the title, body, and labels:
   - Write them fresh for the public. Copy no wording from the handoff, and never mention
     dev-home or handoffs.
   - Leave out anything rule 7 forbids, local paths, PC names, and anything else in the item
     that shouldn't be public. If the item makes no sense without those, say so and stop.
   - Use only labels the repo already has
     (`gh label list --repo <owner>/<repo> --limit 100`), picked to fit the item or as the user
     asked. Ask before creating a label.
   - If the project has issue templates in `.github/ISSUE_TEMPLATE/`, follow the one that fits.
   - Keep double quotes, backticks, and dollar signs out of the title.
4. Show the draft, and file it only after the user says yes to that exact text. If you change
   it, show it again.
5. Write the body to `{{CONTENT_DIR}}/<draft>`, which git ignores, then run
   `gh issue create --repo <owner>/<repo> --title "<title>" --body-file "{{CONTENT_DIR}}/<draft>" --label "<label>"`,
   with one `--label` for each label. If it fails, show the error and change nothing.

The edit: replace the item with `GitHub issue [#<number>](<issue URL>): <title>` in the same
place, and keep under it only the notes that couldn't go in the issue. For text that wasn't in
the handoff, add the link where it fits.

### Issue candidates

After an update, suggest filing an item only when it really makes sense. It must pass every
test:

- This session added or changed it.
- It's a concrete bug, feature, or task that someone outside the project would understand.
- It can be written without anything private.
- It's likely to stay open beyond the next session or two.
- It doesn't link to an issue yet, and it isn't marked "Not for a GitHub issue".

Never suggest anything from Next up, Work in progress, Settled design decisions, Traps, Needs a
live environment, or Local environment. Suggest at most three; most updates have none. Ask in
one line each: "Issue candidate: <section>: <item>. File it?"

- Yes: file it as above.
- No: add `(Not for a GitHub issue: <reason>)` to the end of the item, with the user's reason,
  or `(Not for a GitHub issue)` if they gave none. Mark every declined item, then commit once,
  as in "Changing the handoff". The mark records the user's decision: never suggest a marked
  item again. `/handoff issue` can still file it, and the link replaces the mark.
- No answer: change nothing.

`/handoff issue` with nothing after it lists every item that qualifies by the tests and sections
above, ignoring only the first test, and asks which to file.

## In Codex

Read, `update`, and `next` work, but edit only. Find the handoff with `locate.ps1` as usual,
since it only reads files. Skip every sync, git, and `gh` step, including the issue link checks, and tell the user that Claude will commit and push the change: the next
/handoff in Claude lists the file, and offers to commit it once it has been untouched for 15
minutes. `issue` needs Claude, so say that and stop; skip issue candidates too. On Windows,
Codex runs even approved commands inside its sandbox, so git and `gh` can't use the user's
credentials there. Mention that the handoff may be behind another PC.

## Rules for every handoff

1. Change the handoff only when the user asks (see Commands). If it looks stale, say so and ask.
2. Current state only. An update brings the whole file up to date. No "done" markers,
   dated entries, or running logs; git history holds the history.
3. Private. Never copy, quote, paraphrase, or mention handoff content or dev-home paths in
   project files, commits, PRs, or issues. Treat the project repos as public. The one exception
   is a GitHub issue the user approved word for word through `/handoff issue`, and even that
   never mentions dev-home or handoffs.
4. Verify before acting. Facts were true on the "State as of" date; Next up is the user's plan,
   not a checked fact. Check a bug against the code before fixing it, and follow the project's
   AGENTS.md.
5. Keep it short. Evidence belongs in the project's research notes or the code; point there.
6. Facts about one PC go under "## Local environment: <PC name>", where the PC name is the value
   of the COMPUTERNAME environment variable. Only edit the section for the PC you're on.
7. No secrets, credentials, tenant or account IDs, or personal information about anyone other
   than the user, such as customer or colleague data. Say where a secret is kept, never its
   value.
