---
name: knowledge
description: Private general knowledge base for coding and AI work (languages, tools, platforms, and AI agents such as Claude Code and Codex), kept in the private dev-home repo. Use when the user runs /knowledge (run alone, it syncs the knowledge base with GitHub), before researching a general technical question from scratch, when the user asks to look something up in or add something to the knowledge base, or when a hard-won general finding comes up during work.
allowed-tools: "Bash(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1) Bash(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 *) PowerShell(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1) PowerShell(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 *)"
---

# Knowledge base

The knowledge base is `{{CONTENT_DIR}}/knowledge`, in the user's private repo, dev-home. Its
`README.md` is the index. The rules for files are in `{{SKILL_DIR}}/rules.md`; read them before
adding or changing anything. Run the commands below exactly as written; in Claude Code they are
pre-approved.

Sessions in other projects, and Codex, use dev-home at the same time, so a file there that you
didn't change may be someone's work in progress. Run git in dev-home only through
`{{TOOLS_DIR}}/sync.ps1`, which commits only the files you name and runs one sync at a time.
Never stage, commit, stash, or discard a file yourself.

## Sync with GitHub (plain /knowledge, and before adding)

Run this when the user runs /knowledge with nothing after it, and as step 3 of Add or update. A
lookup reads the local copy and never syncs.

1. Run `pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1`. It syncs with GitHub, then runs setup.
   Pass on anything it prints beyond `OK`:
   - `OFFLINE`: say the knowledge base may be stale, and continue.
   - `LEFT`: leave the file alone. Another session may be editing it.
   - `STALE`: nobody has touched the file for 15 minutes. Ask whether to commit it. On a yes, run
     `pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 -Message "sync: <what changed>" "<path>"`.
   - `UPDATE`: new dev-home-tools commits are available. Tell the user, and continue.
   - `PROBLEM`: show it to the user.
2. Tell the user in one line where things stand: up to date, pulled, pushed, or not checked and
   why.

## With no request

Sync, then list the subjects in the index and ask what to look up or add.

## Look something up

1. Read the index, `{{CONTENT_DIR}}/knowledge/README.md`.
2. Open only the file the index points to.
3. For fast-moving subjects such as `ai-agents`, re-check anything last verified more than about
   three months ago before relying on it, and offer to update the note.

## Propose

Offer a candidate only when it qualifies; most sessions have none. It qualifies in one of two
ways:

- **Finding:** a general fact that took real digging and was checked in this session, by a test
  you ran or documentation you read. Reasoning, memory, and general know-how don't count.
- **Pitfall:** a mistake AI agents make regularly and are likely to make again in the user's
  setup (their operating system, shells, and agents), with a fix checked in this session. It
  recurs if the user says so, if it happened more than once this session, or if it's a known,
  documented problem. One slip isn't enough.

Either way, it must pass the general test (Add or update, step 1) and be worth its token cost: a
future session is likely to need it, and reading it costs less than working it out again. Never
offer:

- anything already in a skill, an instructions file, or this knowledge base (offer to fix the
  existing file instead, if it's wrong or incomplete),
- well-known basics,
- your own reasoning or design choices.

Offer it in one line at a natural stopping point, and wait for a yes:
"Knowledge candidate: <folder>/<file>: <what we learned>. Evidence: <the test we ran or the page
we read; for a pitfall, also how we know it recurs>. Add it?"
If you can't fill in the evidence from this session, don't offer it.

Agents read the knowledge base only when they look something up, so a stored pitfall may not
stop the next one. For a pitfall that hits often and costs real time, you may also offer one
line for `{{CONTENT_DIR}}/rules/global.md`, which loads in every session. Every line
there costs tokens in every session, so offer it separately, and only for the worst ones.

## Add or update (only when asked, or after a yes)

1. Apply the general test: it would still be true in a brand-new project, and it names none of
   the user's functions, files, or tenants. If it fails:
   - About the project and safe to publish: it goes where the project's AGENTS.md says research
     goes. The user approves that commit as usual.
   - About the project but private (current state, local setup, tenant details): it goes in the
     project's handoff.
   - The project has no notes section, or it's unclear whether something is safe to publish:
     ask.
2. Read `{{SKILL_DIR}}/rules.md`, unless you already did this session.
3. Sync with GitHub (above), unless it already ran this turn.
4. Add the finding to the matching topic file, or create one by the rules. Label its evidence
   and date it, with versions. Keep it short, because every line costs tokens each time the file
   is read, and prefer adding to an existing file over creating one. When changing an existing
   fact, follow the rules under "When facts change".
5. If you added, renamed, or split a file, update the index table in
   `{{CONTENT_DIR}}/knowledge/README.md`.
6. Run
   `pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 -Message "knowledge: <folder>/<file>" "<path>" ...`,
   naming every file you created, changed, or deleted (a rename is its old and its new path),
   plus `knowledge/README.md` if the index changed. It commits only those, then syncs.
   - `OFFLINE` or `PENDING`: the commit is safe on this PC, and a later sync pushes it.
   - `PROBLEM`: stop and show it. The files are safe on this PC.
7. Show the user what changed.

In Codex: edit only. Skip the sync and every git step, and tell the user that Claude will commit
and push the change: the next /handoff or plain /knowledge in Claude lists the files, and offers
to commit them once they have been untouched for 15 minutes. Mention that the local copy may be
behind another PC.

Never store secrets, credentials, tenant or account IDs, or personal information about anyone
other than the user, such as customer or colleague data. Never copy knowledge-base text or
dev-home paths into project files, commits, PRs, or issues.
