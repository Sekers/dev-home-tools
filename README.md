# dev-home-tools

**dev-home** is a home base for working with AI coding agents (Claude Code and Codex): a private
GitHub repo of your own, with a copy on each of your PCs, holding what your agents should have
in every session. That's your own rules, your own skills, and anything those skills keep for
you.

**dev-home-tools**, this repo, is the public tooling that makes dev-home work:

- **Setup.** Its `setup.ps1` creates your dev-home the first time you run it, and clones it on
  your other PCs. On each PC, it connects dev-home to Claude Code and Codex, so every session
  loads your rules and skills.
- **Sync.** It keeps dev-home in sync with its online copy, so a change made on one PC reaches
  the others.
  - Setup puts dev-home on GitHub for now (just dev-home: your project repos can be hosted
    anywhere). Automated setup for GitLab, Bitbucket, and Azure DevOps is coming.
- **Privacy.** It tells every session never to copy dev-home into your project repos, or even
  mention it there, so your projects can stay public.
- **Skills.** It comes with ready-made skills, listed below, and sets up any you add to your own
  dev-home.

This repo never holds anyone's own content: that stays in each person's private dev-home.

**What's a skill?** It's like a custom command for your agent: a folder of instructions that
teaches it one task. Type its name to run it, such as `/handoff` in Claude Code or `$handoff` in
Codex, or just ask in your own words, and the agent uses the matching skill on its own. Both
tools support skills in the shared [Agent Skills](https://agentskills.io) format. To learn more,
see skills in the [Claude Code docs](https://code.claude.com/docs/en/skills) and the
[Codex docs](https://learn.chatgpt.com/docs/build-skills).

**Skills included:**

| Skill | What it does |
| --- | --- |
| `handoff` | Keeps one private note per project in your dev-home: what's next, what's in progress, what's waiting on you or on others, and what's left to do. Start a session with `/handoff`, and the agent picks up where the last one stopped, on any of your PCs. |
| `knowledge` | Keeps your own knowledge base in your dev-home: general things you've learned about languages, tools, and AI agents, so no session has to work them out twice. Agents check it before researching or testing a general question, even partway through other work. |

Works with Claude Code, Codex, or both. Windows only, for now. To start, see
[Set up a PC](#set-up-a-pc).

## Requirements

| What | Why | Install |
| --- | --- | --- |
| PowerShell 7.2 or later | Runs the scripts. Windows PowerShell 5.1 can't. | `winget install --id Microsoft.PowerShell --source winget` |
| Git 2.31 or later | Every sync with GitHub. | `winget install --id Git.Git --source winget` |
| GitHub CLI (`gh`) | Creates or clones your dev-home on GitHub, and files issues for `/handoff issue`. | `winget install --id GitHub.cli --source winget` |
| Claude Code, Codex, or both | The agents the skills and rules are for. | Each tool's own installer. |

Open a new PowerShell window after installing, so the tools are on the PATH. Nothing here needs
admin rights.

## Set up a PC

You clone this repo yourself. Setup then creates your dev-home on your first PC, or clones it on
later ones. Use a normal PowerShell 7 window (`pwsh`), not an administrator one.

### 1. Before setup, once per PC

1. Sign in to GitHub: `gh auth login`. Choose HTTPS, and answer yes when it asks to authenticate
   Git with your GitHub credentials. Then git can pull and push without asking, even when an
   agent runs a sync. Signed in earlier without that? Run `gh auth setup-git`.
2. Make sure git knows who you are, because the scripts commit. If git already commits on this
   PC, keep what you have. Otherwise, set at least a name and email:

   ```powershell
   git config --global user.name "Your Name"
   git config --global user.email "you@example.com"
   ```

   - To keep your email address private, use your GitHub no-reply address instead, such as
     `12345678+you@users.noreply.github.com`. GitHub shows yours under Settings > Emails.
   - If you sign your commits, leave that on. Setup turns signing off only inside dev-home, so
     a commit there never stops in the middle of a sync to ask for your signing passphrase. Your
     project repos keep signing as usual.

3. Start Claude Code once, and Codex if you use it, so their folders (`~\.claude`, `~\.codex`)
   exist. Setup skips Codex when `~\.codex` is missing.

### 2. Clone this repo

Clone it into a folder near the root of a drive, where you keep your programming work, such as
`C:\Programming`. Avoid your Documents folder, which is often synced by OneDrive, and OneDrive
can corrupt a git repo. The full path can't have spaces or other characters that need quoting
(letters, digits, `.`, `_`, `-`, and `@` are fine), because setup writes it into commands as it
is. If you use a [Dev Drive](https://learn.microsoft.com/windows/dev-drive/), it's an even
better place, such as `D:\Programming`.

```powershell
gh repo clone Sekers/dev-home-tools C:\Programming\dev-home-tools
```

### 3. Run setup

```powershell
pwsh -NoProfile -File C:\Programming\dev-home-tools\setup.ps1
```

To see what it would change first, add `-WhatIf`. It still asks its first-run questions, but
changes nothing.

The first run asks:

| Question | What to answer |
| --- | --- |
| Your dev-home folder | Where your dev-home is, or should go. Press Enter for the suggestion: a `dev-home` folder next to this one, such as `C:\Programming\dev-home`. The same rules for the path apply. |
| Pull updates automatically? | `y` to take new versions of this repo at every sync, or Enter for no: you're told about them and pull them yourself. See [Updates](#updates). |
| Also set up `~\.claude-<name>`? | Asked for each extra Claude Code folder it finds, one per Claude account you run with `CLAUDE_CONFIG_DIR`. `y` sets that account up too. |
| Clone your existing dev-home (c), create a new private one (n), or stop (s)? | Only when the dev-home folder doesn't exist yet. On your first PC, `n` creates a private repo on GitHub from the files in `starter/`. On every later PC, `c` clones it. Either way, it then asks for the repo's name; Enter accepts `dev-home`. |

Setup can create or clone dev-home only on GitHub for now; automated setup for GitLab,
Bitbucket, and Azure DevOps is coming. If your dev-home is already on one of those, or on your
own git server, clone it into your dev-home folder yourself before running setup. Setup then
uses it as it is, and syncing works the same as with GitHub.

This limit applies only to where dev-home itself is hosted. Your project repos can be anywhere,
or not hosted at all, and the skills work with them the same way. The one exception is filing a
handoff item as an issue, which needs the project on GitHub.

Then it links everything and checks Claude Code's and Codex's settings (see
[What setup changes](#what-setup-changes-on-your-pc) for what and why). When a setting is
missing, it shows the exact lines it would change and asks first. On a `y`, it saves a dated
backup of the file, such as `settings.json.bak-20260926-101500`, before writing. It never edits a
file it can't fully read, such as a `settings.json` with comments; it prints what to add by hand
instead.

### 4. Restart, and check

Restart Claude Code and Codex, so they load the skills and rules. Run setup again, and repeat
until it ends with "All checks passed." Then you can delete the backups.

After that, you rarely need to run setup yourself. Every sync runs it quietly, so changes to the
skills, and skills you add on another PC, reach this one.

Your answers are saved in `local-settings.json` in this folder. To change one later, edit that
file and run setup again: `autoUpdate` is `true` or `false`, and `claudeConfigDirs` lists extra
Claude Code folders, such as `"~/.claude-second"`. To use a different dev-home folder, run setup
with `-ContentDir <folder>`.

## Day to day

Run these in any project, in as many sessions at once as you like. Type a command below, or ask
in plain words and the agent uses the matching skill. In Codex, type `$` instead of `/`, such as
`$handoff`.

A typical day with the included skills:

1. In a project, run `/handoff`. The agent syncs your dev-home with GitHub, reads the project's
   handoff, and tells you what's next.
2. Work as usual. When you learn something worth keeping for every project, the agent may offer
   to add it to your knowledge base.
3. Before you stop, run `/handoff update`. The agent writes down where things stand, and saves
   it to GitHub so your other PCs get it.
4. Next time, on this PC or another one, `/handoff` picks up from there.

### Handoffs

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
- **Next up changes only when you say so.** When an update finishes it, the agent asks before
  clearing it.
- **Every handoff has the same sections,** from `skills/handoff/template.md`; the handoff skill
  says what goes in each. `/handoff update` brings an older handoff in line, and asks before it
  moves anything out.
- **Issues.** After an update, the agent may suggest up to three items as issues, only when
  filing one really makes sense. Say no, and it marks the item so it never suggests it again,
  then commits and pushes that; the question says so. Filing always shows you the draft and waits
  for your yes. Issues work in Claude Code only, for projects on GitHub, with `gh` signed in.
- **In Codex, handoff commands edit but don't commit.** The next `/handoff` in Claude Code lists
  the file, and offers to commit and push it once nobody has touched it for 15 minutes. The same
  goes for anything you edit by hand in dev-home.

**Where handoffs are kept.** The handoff skill finds each project's handoff from the address the
repo syncs with (its `origin`), so it's the same on every PC, whatever the folder is called.

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
yet, a shallow clone, or a folder outside git uses just the folder name. When a project moves
(renamed, transferred, or published for the first time), the agent can't find its handoff at the
new path, so it lists the existing ones and offers to move the right one.

### Knowledge base

These read and update the knowledge base in your dev-home.

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
- Anything about one project stays out of the knowledge base.

### Your own rules and skills

- **Rules.** Put your own always-on rules in `rules/global.md` in your dev-home. Every session,
  in both tools and on every PC, loads them along with the core rules: the always-on rules that
  come with dev-home-tools, in its `rules/core.md`, which the skills and scripts need every
  session to follow. Yours win where the two conflict, because the core rules say so. Your file
  starts as the empty template from `starter/`, and after that it's yours. Keep it short: every
  line costs tokens in every session.
  - **How it loads.** The file name is this project's own. Setup hooks it into each tool's
    standard place for always-on instructions: Claude Code's
    [user-level rules](https://code.claude.com/docs/en/memory#user-level-rules) folder, and
    Codex's [global `AGENTS.md`](https://learn.chatgpt.com/docs/agent-configuration/agents-md).
  - **Already using `~\.claude\CLAUDE.md`?** It keeps loading in Claude Code, alongside these
    rules, and setup never touches it. But only Claude Code reads it, and only for that account
    on that PC. Move anything you want everywhere into `global.md`, and take it out of
    `CLAUDE.md` so Claude doesn't read it twice.
  - **Already have your own `~\.codex\AGENTS.md`?** Setup needs that file for the joined rules,
    so it leaves yours alone and reports it. Move what you want to keep into `global.md`, delete
    the file, and run setup again.
- **Skills.** Create `skills/<name>/SKILL.md` in your dev-home, with standard frontmatter only:
  `name` (the same as the folder), `description`, and optionally `allowed-tools`. Run
  `pwsh -NoProfile -File C:\Programming\dev-home-tools\setup.ps1 -Quiet` to link it, and commit
  it
  (ask an agent, or wait for the next `/handoff` to offer). Your other PCs link it at their next
  sync. A skill can't share a name with one in this repo.

## What's in your dev-home

| Path | What it is |
| --- | --- |
| `handoffs/` | One handoff per project, filed by where the project is hosted (see [Handoffs](#handoffs)). |
| `knowledge/` | Your knowledge base. `knowledge/README.md` is its index. |
| `rules/global.md` | Your own rules, loaded in every session. |
| `skills/` | Skills of your own, if you add any. |
| `AGENTS.md`, `README.md` | Notes on working in dev-home itself, for agents and for you. |
| `.drafts/` | Scratch space for text that leaves dev-home, such as GitHub issue bodies. Git ignores it. |

Setup creates it from the files in this repo's `starter/` folder. After that, its files are
yours: updates to dev-home-tools never change them.

## Updates

When a new version of dev-home-tools comes out on GitHub, the copy on your PC doesn't change by
itself. Instead, every time an agent syncs your dev-home (when you run `/handoff`, for example),
it also checks GitHub for a new version of dev-home-tools. What happens next depends on the
`autoUpdate` setting you chose the first time you ran setup:

| `autoUpdate` | When a new version is found |
| --- | --- |
| Off (the default) | Nothing is installed. The agent tells you an update is waiting, and you decide when to look at it and install it (below). |
| On | The sync installs it right away. |

To look at a waiting update and install it, run:

```powershell
pwsh -NoProfile -File C:\Programming\dev-home-tools\update.ps1
```

It lists each change and the files it touches, and installs them only if you answer `y`.

- **After any update,** setup runs by itself, so the new skills and rules take effect.
- **An update changes only your dev-home-tools folder.** Your dev-home and everything in it stay
  as they are.
- **To switch `autoUpdate`,** set it to `true` or `false` in `local-settings.json`, in your
  dev-home-tools folder.
- **If you've made commits of your own** in your dev-home-tools folder, updates are never
  installed for you, and `update.ps1` won't install them either. Pull and merge them yourself
  with git.

## The scripts

| Script | What it's for |
| --- | --- |
| `setup.ps1` | Sets up this PC. Safe to run any number of times. `-WhatIf` previews; `-Quiet` prints only changes and problems, and never asks (agents run it this way); `-ContentDir <folder>` points it at a different dev-home. |
| `sync.ps1` | Syncs your dev-home with GitHub, and commits only the files it's given. Agents run all their git in dev-home through it. It also checks for new versions of dev-home-tools, and runs setup when it's done. You can run it too. |
| `update.ps1` | Shows the dev-home-tools commits waiting on GitHub, and pulls them after a yes. |

Agents pass on what `sync.ps1` reports:

| Word | Meaning |
| --- | --- |
| `OK` | Up to date, or nothing to do. |
| `COMMITTED` | Committed the files it was given. |
| `PULLED`, `MERGED` | Brought in commits from GitHub. `MERGED` means two PCs both had new commits. |
| `PUSHED` | Sent this PC's commits to GitHub. |
| `PENDING` | Commits not pushed yet. The next sync pushes them. |
| `OFFLINE` | GitHub couldn't be reached, so this copy may be behind. |
| `LEFT` | A file changed recently and isn't committed. Another session may be working on it. |
| `STALE` | An uncommitted file nobody has touched for 15 minutes. The agent asks whether to commit and push it. |
| `UPDATE` | New dev-home-tools commits are waiting. |
| `PROBLEM` | Needs you. The message says what to do. |

## What setup changes on your PC

Setup doesn't copy the skills and rules into Claude Code's and Codex's folders. It adds links
there instead: a link is a folder entry that points to a folder somewhere else, and the tools
read through it as if the files were right there. So when a sync or an update changes a skill
or a rule, the tools see the change at once, with nothing to copy. Setup makes folder links as
directory junctions, or as symbolic links when Windows Developer Mode is on; neither needs admin
rights.

- **In your dev-home-tools folder,** two things that belong to this PC only. Git ignores both, so
  they never go to GitHub, and an update never overwrites them.
  - `.generated/`: this PC's copy of the skills and core rules. In this repo, they hold a
    placeholder wherever a folder path goes, because everyone keeps their folders in different
    places. Setup writes a copy with this PC's real paths filled in, and that copy is what the
    tools use. The paths have to be written out in full, because the commands a skill may run
    without asking you are matched by their exact text. Setup rewrites this folder at every
    sync, so don't edit it; put skills of your own in your dev-home.
  - `local-settings.json`: this PC's answers to setup's questions: where your dev-home is,
    whether to install updates automatically, and which extra Claude Code folders to set up.
    The scripts read it to find your dev-home.
- **In each Claude Code folder** (`~\.claude`, plus any extra ones):
  - Links in `skills\` to each skill (this repo's, and your own from dev-home),
    `rules\dev-home-tools` to the core rules, and `rules\dev-home` to your dev-home's `rules\`.
  - After your yes, `settings.json` gets your dev-home and dev-home-tools folders in
    `permissions.additionalDirectories`, so Claude Code can use them from any project.
  - Your own `CLAUDE.md` there is never touched.
- **For Codex,** when `~\.codex` exists:
  - Links in `~\.agents\skills\`.
  - `~\.codex\AGENTS.md`, the core rules and your own joined into one file, because Codex reads
    only one always-on file. Setup rewrites it at every sync, but never replaces an
    `AGENTS.md` it didn't write.
  - After your yes, `config.toml` gets dev-home in `[sandbox_workspace_write]` `writable_roots`,
    so Codex can edit handoffs and knowledge from any project. It also gets
    `project_doc_max_bytes = 65536`. Codex joins its global `AGENTS.md` with a project's own
    `AGENTS.md` files and stops reading at 32 KiB by default. The global file comes first, so
    the cut would fall on the project's own instructions, without a warning. Twice the default
    leaves room.
- **In your dev-home's own git config:** commit signing off, and pulls that merge rather than
  rebase. With signing off, a commit never stops in the middle of a sync to ask for your signing
  passphrase. Your project repos keep signing as usual.

**To remove it all:** delete each link with `cmd /c rmdir <link>`, delete `~\.codex\AGENTS.md`,
take the added lines out of the settings files, then delete your dev-home-tools folder. Your
dev-home stays as it is.

## Safety and privacy

- **Your project repos are treated as public.** The core rules tell agents never to quote
  dev-home, paraphrase its notes, or mention that it exists in a project's files, commits, PRs,
  or issues. The one way handoff content reaches a project is an issue you approve word for word.
- **No secrets in dev-home:** no credentials, tenant or account IDs, or personal information
  about anyone else. Note where a secret is kept, never its value.
- **`sync.ps1` commits only what it's given.** Several sessions and PCs share dev-home, so any
  other changed file may be someone's work in progress. It never stages, commits, stashes,
  resets, or discards those. It runs one sync at a time, undoes a merge that conflicts, and never
  deletes a git lock file.
- **`setup.ps1` replaces only its own work:** its generated files, links whose target is gone,
  and links it made to skills that no longer exist. Anything else in its way is reported, not
  changed. Settings changes are shown first, need your yes, and keep a backup.
- **Tooling updates wait for you** unless you turn on `autoUpdate`, because whoever controls this
  repo on GitHub controls code that runs on your PC.
- **Never run `Remove-Item -Recurse`** on `~\.claude`, `~\.claude-*`, or `~\.agents`. It follows
  the links into your dev-home and deletes what's there. Remove a single link with
  `cmd /c rmdir <link>`.
- **Edit your rules in dev-home,** in `rules/global.md`, never in `~\.codex\AGENTS.md`,
  which setup rewrites.
- If PowerShell says a script isn't digitally signed (after downloading this repo as a zip, for
  example), run `Unblock-File <script>` once.

## Troubleshooting

- **Setup ends with "problem(s) to fix".** Each `PROBLEM` line says what to do. Fix those, then
  run setup again.
- **`/handoff` says the dev-home rules aren't loaded.** Restart the agent. If it still says so,
  run setup and read its output. In the Claude desktop app's Cowork sessions, Claude Code skips
  rule folders linked from outside the session's folder, so the rules may not load there.
- **A skill seems to be missing.** Run setup with `-Quiet`, then restart the agent.
- **Setup reports a dev-home repo with no commits.** A setup run stopped partway through
  creating it, for example because git didn't know your name yet. If that folder holds nothing
  you need, delete it, fix the cause, and run setup again.

## Working on dev-home-tools

| Path | What it is |
| --- | --- |
| `skills/` | The skills, one folder each, with placeholders where paths go. Setup fills them in for each PC. |
| `rules/core.md` | The core rules every session loads, along with your own. |
| `setup.ps1`, `sync.ps1`, `update.ps1` | The scripts (see [The scripts](#the-scripts)). |
| `starter/` | The files setup copies into a brand-new dev-home. |
| `tests/` | The test runner. |

[AGENTS.md](AGENTS.md) has the rules for changing this repo, for people and agents alike. Before
committing, run:

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

It tests the working tree in throwaway copies under `.test-sandbox/`, never your real profile or
dev-home, and needs no network. Never point this folder's scripts at a test dev-home: they would
rewrite the files your real links depend on.

## License

MIT. See [LICENSE](LICENSE).
