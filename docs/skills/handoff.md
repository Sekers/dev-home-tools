# Handoffs

These read and update the current project's handoff, which lives in your dev-home. The exact
steps agents follow are in the skill itself:
[`SKILL.md`](../../templates/skills/handoff/SKILL.md).

| Command | What it does |
| --- | --- |
| `/handoff` | Syncs your dev-home with GitHub, then summarizes this project's handoff, starting with Next up, with a link to the file. If the project has commits since the one the handoff last checked, it says how many and what they cover. If this copy of the project lacks commits that check had, it says to pull first. |
| `/handoff <question>` | The same, then answers the question. |
| `/handoff update` | Brings the whole handoff up to date, including what this session decided, built, changed, and learned, and lists where each went so you can spot a gap. If Next up looks done, asks before clearing it. |
| `/handoff update <text>` | The same, with your text worked in, in any words. The text can also set, add to, or clear Next up. |
| `/handoff next` | Shows Next up. |
| `/handoff next <text>` | Replaces Next up. Nothing else changes. |
| `/handoff next clear` | Empties Next up. |
| `/handoff issue` | Lists the items that could become GitHub issues. |
| `/handoff issue <item>` | Files an item as an issue in the project's GitHub repo, and replaces the item with a link to it. For now, only in Claude Code, for projects on GitHub, with `gh` signed in. |
| `/handoff audit` | Has a fresh agent read the handoff as a new session would, then fixes what it can and asks you about the rest. See [Audits](#audits). |
| `/handoff audit <model> <effort>` | The same, on that model or at that effort, or both, such as `/handoff audit sonnet xhigh`. |

A command that changes the handoff saves, commits, and pushes only that file: typing the command
is your go-ahead. Some examples:

| You type | What happens |
| --- | --- |
| `/handoff what's left before the release?` | Summarizes the handoff, then answers. |
| `/handoff update the vendor says the fix ships Friday` | Updates the handoff, with that under Waiting on others. |
| `/handoff update next: release 1.2.0` | Updates the handoff, and Next up becomes "Release 1.2.0". |
| `/handoff next also push the wiki after the release` | Adds that to Next up. |
| `/handoff next clear the old wiki pages` | Next up becomes "Clear the old wiki pages". Only `clear` on its own empties Next up. |
| `/handoff next steps?` | Reads as a question, so the agent answers it and asks before changing anything. |
| `/handoff issue Bugs 1` | Drafts an issue from that item, files it after your yes, and replaces the item with a link. |
| `/handoff audit the to-dos` | Reads as a question, so the agent answers it and asks before starting an audit. |

- **A command changes the handoff right away,** and commits and pushes it. So does a request in
  plain words that matches one command exactly, such as "update the handoff"; the agent says
  which command it took it as. Anything else, such as "we should add a to-do for this", gets a
  draft first, ending with "Save, commit, and push this?". A yes covers that one change only,
  never later ones, and "save it" saves without committing. A plan you approved, or a passing
  remark, never changes the handoff.
- **Commits cover only the handoff.** If an update moves an item into your project's own files,
  such as a decision into its AGENTS.md, the agent shows you the text first and never commits
  those files: your project's own rules, and your global rules, decide that.
- **Next up changes only when you say so.** When an update finishes it, the agent asks before
  clearing it.
- **Every handoff has the same sections,** from `templates/skills/handoff/template.md`; the
  handoff skill says what goes in each. `/handoff update` brings an older handoff in line, and
  asks before it moves anything out.
- **Environment notes follow the evidence.** An environment can be a computer, VM, container,
  remote server, or cloud service. An agent normally updates the environment it's working in,
  but it can update another environment when it has reliable evidence about it, such as your
  report, output from there, direct inspection, or a project-wide change. It never infers one
  environment's state from another.
- **Issues.** After an update, the agent may suggest up to three items as issues, only when
  filing one really makes sense: bugs, feature requests, and concrete tasks, never a decision
  still to make. For each, you can create a GitHub issue for it, skip it (no reminder), have it
  suggested again next session or in a number of days, or say no (never ask again). Whatever you
  answer, the item stays in the handoff; a new issue turns it into a link to the issue. Skip
  leaves no trace, so the item comes up again only if a later session changes it. A reminder or
  a no marks the item, and the mark is committed and pushed; the question says so. No item is
  suggested twice in one session. Filing always shows you the draft and waits for your yes.
  Issues work in Claude Code only, for projects on GitHub, with `gh` signed in.
- **In Codex, handoff commands edit but don't commit.** On Windows, Codex runs even the commands
  you approve inside its sandbox, where git and `gh` can't use your GitHub credentials. So the
  next `/handoff` in Claude Code lists the file, and offers to commit and push it once nobody has
  touched it for 15 minutes. The same goes for anything you edit by hand in dev-home.

## Audits

**`/handoff audit` has a second agent read the handoff as a new session would.** That agent knows
nothing about your sessions. It reads the whole handoff and the project files its items point
to, then reports every item a new session couldn't act on without asking you: one that's out of
date, one that contradicts another item or your project's files, or one that doesn't say what to
do next, or why. Your agent then checks each finding, fixes what the handoff or your project's
files settle, commits, and lists what it changed and what only you can answer. It never changes
Next up, and never rewords text you approved; it asks instead.

An update fixes what the current session changed. An audit finds what earlier sessions left
behind. Neither can find something nobody wrote down.

**When it's worth running:**

- before someone else, another PC, or another AI tool picks up the work
- after many sessions since the last audit, or when the handoff has grown long
- when a session was misled by something wrong in the handoff

**What it costs:** it takes minutes rather than seconds, and costs more than most commands. The
longer the handoff, and the more project files its items name, the more it costs. So run one now
and then, not after every update. In Claude Code you can keep working while it runs; in Codex,
the chat waits.

**Choosing a model and effort:** an audit runs on your session's model and effort. To choose
others, name them: `/handoff audit sonnet xhigh`. A model named on its own runs at xhigh. In
Claude Code, on one long handoff, tested on 2026-10-08 with the 5.5 models (newer models and
prices may change this):

- **Opus at medium:** quick and thorough; the best balance of time and results.
- **Sonnet at xhigh:** the most thorough, and about as slow as Opus at xhigh.
- **Haiku at xhigh:** the cheapest by far, but the slowest of the useful choices.
- **Avoid** low or medium effort on Sonnet or Haiku, which missed most problems, and max on any
  model, which was slower and found no more.

No audit found every problem, and two identical audits found different ones, so a second audit
often finds more.

## Where handoffs are kept

The handoff skill finds each project's handoff from the address the repo syncs with (its
`origin`), so it's the same on every PC, whatever the folder is called.

| Project | Its handoff in dev-home |
| --- | --- |
| On GitHub | `handoffs/github/<owner>/<repo>/` |
| On GitLab | `handoffs/gitlab/<group>/<project>/` (subgroups add levels) |
| On Bitbucket | `handoffs/bitbucket/<workspace>/<repo>/` |
| On Azure DevOps | `handoffs/azure-devops/<org>/<project>/<repo>/` |
| Hosted anywhere else | `handoffs/other/<folder>-<first commit>/` |
| No remote | `handoffs/local/<folder>-<first commit>/` |

`<first commit>` is the first 7 characters of the repo's first commit. It's the same in every
clone, so two projects with the same folder name get separate handoffs. A repo with no commits
yet, a shallow clone, or a folder outside git uses just the folder name.

When the agent finds no handoff at a project's path, it lists the existing ones and asks whether
one of them is this project's under an old address, as happens when a project is renamed,
transferred, or published for the first time. It offers to move that one, or, if none is, to
create a new handoff. Either way, it asks first, then commits and pushes.
