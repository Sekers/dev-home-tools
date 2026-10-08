# Knowledge base

These read and update the knowledge base in your dev-home. The exact steps agents follow are in
the skill itself: [`SKILL.md`](../../templates/skills/knowledge/SKILL.md).

| Command | What it does |
| --- | --- |
| `/knowledge` | Syncs your dev-home with GitHub, then lists the subjects and asks what to look up or add. |
| `/knowledge <question>` | Looks it up in this PC's copy, without syncing. |
| `/knowledge add <what you learned>` | Checks that it's general, files it by the skill's rules, then commits and pushes only the files it changed: typing the command is your go-ahead. A request in plain words works the same when it's a direct instruction, such as "add this to the knowledge base: ..."; anything else gets a draft first. |

- Agents check the knowledge base before researching or testing a general question, or asking
  you to test one, even partway through other work.
- They offer a "Knowledge candidate", with its evidence, only for a finding checked in that
  session, or a pitfall agents keep hitting. Most sessions have none. The offer ends "Add it,
  commit, and push?", and nothing is added without your yes.
- A note has to help any project that uses the same tool, library, or service, whoever makes it,
  your own projects included. What only helps work on one project's own code stays in that
  project. When a finding is a normal docs item for a project whose docs you can change, the
  offer asks whether it goes there instead.
- Commits cover only the knowledge base. If the agent offers to fix a skill or an instructions
  file instead, it shows you the text first and never commits that file: the rules that cover
  that file decide that, meaning the skill that looks after it, if there is one, that repo's own
  rules, and your global rules.
- In Codex, knowledge commands edit but don't commit, for the same reason as
  [handoff commands](handoff.md). The next sync in Claude Code, such as a plain `/knowledge`,
  lists the files, and offers to commit and push them once nobody has touched them for 15
  minutes.
