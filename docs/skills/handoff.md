# Handoffs

These read and update the current project's handoff, which lives in your dev-home.

| Command | What it does |
| --- | --- |
| `/handoff` | Syncs your dev-home with GitHub, then summarizes this project's handoff, starting with Next up, with a link to the file. |
| `/handoff <question>` | The same, then answers the question. |
| `/handoff update` | Brings the whole handoff up to date. If Next up looks done, asks before clearing it. |
| `/handoff update <text>` | The same, with your text worked in, in any words. The text can also set, add to, or clear Next up. |
| `/handoff next` | Shows Next up. |
| `/handoff next <text>` | Replaces Next up. Nothing else changes. |
| `/handoff next clear` | Empties Next up. |
| `/handoff issue` | Lists the items that could become GitHub issues. |
| `/handoff issue <item>` | Files an item as an issue in the project's GitHub repo, and replaces the item with a link to it. For now, only in Claude Code, for projects on GitHub, with `gh` signed in. |

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
- **Issues.** After an update, the agent may suggest up to three items as issues, only when
  filing one really makes sense. Say no, and it marks the item so it never suggests it again,
  then commits and pushes that; the question says so. Filing always shows you the draft and waits
  for your yes. Issues work in Claude Code only, for projects on GitHub, with `gh` signed in.
- **In Codex, handoff commands edit but don't commit.** On Windows, Codex runs even the commands
  you approve inside its sandbox, where git and `gh` can't use your GitHub credentials. So the
  next `/handoff` in Claude Code lists the file, and offers to commit and push it once nobody has
  touched it for 15 minutes. The same goes for anything you edit by hand in dev-home.

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
