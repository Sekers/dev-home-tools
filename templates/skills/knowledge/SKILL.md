---
name: knowledge
description: Private general knowledge base for coding and AI work (languages, tools, platforms, and AI agents such as Claude Code and Codex), kept in the private dev-home repo. Check it before researching or testing a general question about these, or asking the user to test one, even partway through other work. Also use when the user runs /knowledge (run alone, it syncs the knowledge base with GitHub), asks to look something up in or add something to the knowledge base, or when a hard-won general finding comes up during work.
allowed-tools: "Bash(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1) Bash(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 *) PowerShell(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1) PowerShell(pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1 *)"
---

# Knowledge base

The knowledge base is `{{CONTENT_DIR}}/knowledge`, in the user's private repo, dev-home. Its
`README.md` is the index. The rules for filing notes are in `{{SKILL_DIR}}/filing-rules.md`;
read them before adding or changing anything. Run the commands below exactly as written; in
Claude Code they are pre-approved.

Sessions in other projects, and Codex, use dev-home at the same time, so a file there that you
didn't change may be someone's work in progress. Run git in dev-home only through
`{{TOOLS_DIR}}/sync.ps1`, which commits only the files you name and runs one sync at a time.
Never stage, commit, stash, or discard a file yourself.

## Sync with GitHub (plain /knowledge, and before adding)

Run this when the user runs /knowledge with nothing after it, and as step 3 of Add or update. A
lookup reads the local copy and never syncs.

1. Run `pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1`. It syncs with GitHub, then runs setup.
   Pass on anything it prints beyond `OK`:
   - `OFFLINE`: GitHub couldn't be reached. When the line is about dev-home, say the knowledge
     base may be stale; when it's about dev-home-tools, say its updates weren't checked. Then
     continue.
   - `LEFT`: leave the file alone. Another session may be editing it.
   - `STALE`: nobody has touched the file for 15 minutes. Ask "Commit and push it?". On a yes, run
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
- well-known basics: facts an agent starting a fresh session would already apply correctly, such
  as that `git add` stages files. It doesn't matter whether the user knows it, or whether you know
  it now: if an agent got it wrong this session, it isn't a basic (it still has to qualify above),
- your own reasoning or design choices.

Offer it in one line at a natural stopping point, and wait for a yes:
"Knowledge candidate: <folder>/<file>: <what we learned>. Evidence: <the test we ran or the page
we read; for a pitfall, also how we know it recurs>. Add it, commit, and push?"
If you can't fill in the evidence from this session, don't offer it.

## When to change, commit, and push

These rules say when you may change a file, and when you may commit and push it. They apply to
the files this skill works on in dev-home: the knowledge base's notes and its index, and any file
a sync lists as `STALE`. For those, follow these rules rather than any rule written for the
user's project repos. Committing and pushing happen together, in one run of `sync.ps1`, so
they're approved together. Any other file, such as a skill or an instructions file you offer to
fix (see "Propose"), is edited only after a yes to the exact text. This skill never commits it:
committing it follows the rules that cover that file: the skill that looks after it, if there is
one, that repo's own rules, and the user's global rules.

- A command the user typed is the go-ahead for that one change: make it, commit it, and push it.
- A request in plain words works the same way only when it's a direct instruction to do exactly
  what one command does, such as "add this to the knowledge base: ...". Say which command you're
  treating it as, then act. None of these is a direct instruction: hedged wording ("we should",
  "maybe", "I wonder"), a question, several requests at once, or anything you're unsure about.
- Any other request for a change gets a draft first: the exact text you'd add, change, or remove,
  and where, ending with one question: "Save, commit, and push this?". A plain yes covers all
  three, for that draft only. If you change the draft, show it again and ask again.
- If the reply names only some of the three, such as "save it", do only those, and say what you
  left undone. `sync.ps1` pushes every commit it makes, so for "commit, but don't push", say so
  and leave the change uncommitted.
- When a request could be a read or a change, treat it as a read and ask.
- Not a request at all, so change nothing: a remark, or a plan the user approved that mentions
  the knowledge base. Say what you'd add, and name the command that would do it.
- When you offer a change yourself that would be its own commit, such as adding a finding, say
  in the same question that it will be committed and pushed: "Add it, commit, and push?".
- One command or one yes covers only the change it was given for, never a later one, even in the
  same session or for the same file. An earlier "commit everything" doesn't cover changes made
  after it.
- A plain sync, `sync.ps1` with no `-Message`, needs no yes, because it never commits a changed
  file. It brings in other PCs' commits, merging them when both PCs have new ones, and pushes
  commits already made on this PC.

## Add or update

The typed command is `/knowledge add <what you learned>`. Go ahead only as "When to change,
commit, and push" says, or after a yes to a candidate you offered.

1. Apply the general test: it would still be true in a brand-new project, and it names none of
   the user's functions, files, or tenants. If it fails, it doesn't belong in the knowledge base:
   tell the user why, and add nothing.
2. Read `{{SKILL_DIR}}/filing-rules.md`, unless you already did this session.
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

Commits in dev-home are unsigned on purpose: setup turns signing off in that repo's own git
config. That is not bypassing signing, and the project repos keep signing as usual.

In Codex: edit only, so leave "commit, and push" out of your questions: a draft ends with "Save
this?", and a candidate with "Add it?". Skip the sync and every git step, and tell the user that
Claude will commit and push the change: the next sync in Claude, such as a plain /knowledge,
lists the files, and offers to commit and push them once they have been untouched for 15 minutes.
Mention that the local copy may be behind another PC.

Never store secrets, credentials, tenant or account IDs, or personal information about anyone
other than the user, such as customer or colleague data. Never copy knowledge-base text or
dev-home paths into project files, commits, PRs, or issues.
