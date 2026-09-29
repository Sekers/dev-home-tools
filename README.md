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
| [`handoff`](templates/skills/handoff/SKILL.md) | Keeps one private note per project in your dev-home: what's next, what's in progress, what's waiting on you or on others, and what's left to do. Start a session with `/handoff`, and the agent picks up where the last one stopped, on any of your PCs. |
| [`knowledge`](templates/skills/knowledge/SKILL.md) | Keeps your own knowledge base in your dev-home: general things you've learned about languages, tools, and AI agents, so no session has to work them out twice. Agents check it before researching or testing a general question, even partway through other work. |

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
| Pull updates automatically? | `y` to install new versions of this repo as soon as a sync finds them, or Enter for no: you're told about them and install them yourself. See [Updates](#updates). |
| Also set up `~\.claude-<name>`? | Asked for each extra Claude Code folder it finds, one per Claude account you run with `CLAUDE_CONFIG_DIR`. `y` sets that account up too. |
| Clone your existing dev-home (c), create a new private one (n), or stop (s)? | Only when the dev-home folder doesn't exist yet. On your first PC, `n` creates a private repo on GitHub from the files in `templates/dev-home-starter/`. On every later PC, `c` clones it. Either way, it then asks for the repo's name; Enter accepts `dev-home`. |

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

After that, you rarely need to run setup yourself. Syncs run it quietly, so changes to the
skills, and skills you add on another PC, reach this one. The one exception is a skill you've
just created on this PC: it's linked at the next `/handoff`, or right away when you run setup
with `-Quiet` (see [Your own rules and skills](#your-own-rules-and-skills)).

Your answers are saved in `local-settings.json` in this folder. To change one later, edit that
file and run setup again: `autoUpdate` is `true` or `false`, and `claudeConfigDirs` lists extra
Claude Code folders, such as `"~/.claude-second"`. To use a different dev-home folder, run setup
with `-ContentDir <folder>`.

## Day to day

Run the skills in any project, in as many sessions at once as you like. Type one of the commands
under [Skills](#skills), or ask in plain words and the agent uses the matching skill. In Codex,
type `$` instead of `/`, such as `$handoff`.

A typical day with the included skills:

1. In a project, run `/handoff`. The agent syncs your dev-home with GitHub, reads the project's
   handoff, and tells you what's next. For a project with no handoff yet, it offers to create
   one.
2. Work as usual. When you learn something worth keeping for every project, the agent may offer
   to add it to your knowledge base.
3. Before you stop, run `/handoff update`. The agent writes down where things stand, and saves
   it to GitHub so your other PCs get it.
4. Next time, on this PC or another one, `/handoff` picks up from there.

## Skills

These skills come with dev-home-tools. To add your own, see
[Your own rules and skills](#your-own-rules-and-skills).

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
- **In Codex, handoff commands edit but don't commit.** On Windows, Codex runs even the commands
  you approve inside its sandbox, where git and `gh` can't use your GitHub credentials. So the
  next `/handoff` in Claude Code lists the file, and offers to commit and push it once nobody has
  touched it for 15 minutes. The same goes for anything you edit by hand in dev-home.

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
yet, a shallow clone, or a folder outside git uses just the folder name.

When the agent finds no handoff at a project's path, it lists the existing ones and asks whether
one of them is this project's under an old address, as happens when a project is renamed,
transferred, or published for the first time. It offers to move that one, or, if none is, to
create a new handoff. Either way, it asks first, then commits and pushes.

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
- In Codex, knowledge commands edit but don't commit, for the same reason as
  [handoff commands](#handoffs). The next sync in Claude Code, such as a plain `/knowledge`,
  lists the files, and offers to commit and push them once nobody has touched them for 15
  minutes.

## Your own rules and skills

- **Rules.** Every session, in both tools and on every PC, loads two sets of always-on rules:
  - **Your global rules**, in `global-rules/global-rules.md` in your dev-home: your own
    preferences for every project. The file starts as the empty template from
    `templates/dev-home-starter/`, and after that it's yours to edit.
  - **The operating rules**, which come with dev-home-tools, in
    [`templates/operating-rules/operating-rules.md`](templates/operating-rules/operating-rules.md):
    how every session works with your dev-home, which the skills and scripts depend on. They're
    the same for everyone, and updates to dev-home-tools change them.

  Your global rules win where the two conflict, because the operating rules say so. Keep yours
  short: every line costs tokens in every session.
  - **How they load.** Setup hooks both into each tool's standard place for always-on
    instructions: Claude Code's
    [user-level rules](https://code.claude.com/docs/en/memory#user-level-rules) folder, as the
    links `dev-home-global-rules` and `dev-home-operating-rules`, and Codex's
    [global `AGENTS.md`](https://learn.chatgpt.com/docs/agent-configuration/agents-md), joined
    into one file.
  - **Already using `~\.claude\CLAUDE.md`?** It keeps loading in Claude Code, alongside these
    rules, and setup never touches it. But only Claude Code reads it, and only for that account
    on that PC. Move anything you want everywhere into your global rules, and take it out of
    `CLAUDE.md` so Claude doesn't read it twice.
  - **Already have your own `~\.codex\AGENTS.md`?** Setup needs that file for the joined rules,
    so it leaves yours alone and reports it. Move what you want to keep into your global rules,
    delete the file, and run setup again.
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
| `global-rules/global-rules.md` | Your global rules: your own preferences for every project, loaded in every session. |
| `skills/` | Skills of your own, if you add any. |
| `AGENTS.md`, `README.md` | Notes on working in dev-home itself, for agents and for you. |
| `.drafts/` | Scratch space for text that leaves dev-home, such as GitHub issue bodies. Git ignores it. |

Setup creates it from the files in this repo's `templates/dev-home-starter/` folder. After that,
its files are yours: updates to dev-home-tools never change them.

## Updates

Your copy of dev-home-tools never changes by itself. Instead, each sync that isn't committing a
change, such as the one every `/handoff` starts with, checks GitHub for new commits to
dev-home-tools. What happens when some are waiting depends on the `autoUpdate` setting you chose
the first time you ran setup:

| `autoUpdate` | When new commits are waiting | What you do |
| --- | --- | --- |
| Off (the default) | Nothing is installed, and the agent tells you an update is waiting. | When you're ready, run `update.ps1` (below). It lists the commits and the files they change, and installs them only if you answer `y`. |
| On | The sync installs them, and the agent tells you it did. | Nothing. |

```powershell
pwsh -NoProfile -File C:\Programming\dev-home-tools\update.ps1
```

Either way, `update.ps1` does the work: the sync runs it quietly, and you run it yourself to look
first. So an update is always installed the same way:

- **It only moves your copy forward to GitHub's version.** It never merges, so if you've made
  commits of your own in your dev-home-tools folder, nothing is installed, and the agent says
  so: pull and merge the update yourself with git. A change you haven't committed is never
  overwritten either: an update that touches the same file waits until it's gone.
- **Setup runs afterwards,** so the new skills and rules take effect.
- **It changes only your dev-home-tools folder.** Your dev-home and everything in it stay as
  they are.

To switch `autoUpdate`, set it to `true` or `false` in `local-settings.json`, in your
dev-home-tools folder.

## The scripts

| Script | What it's for |
| --- | --- |
| `setup.ps1` | Sets up this PC. Safe to run any number of times. `-WhatIf` previews; `-Quiet` prints only changes and problems, and never asks (agents run it this way); `-ContentDir <folder>` points it at a different dev-home. |
| `sync.ps1` | Syncs your dev-home with GitHub, and commits only the files it's given. Agents run all their git in dev-home through it. Then it runs `update.ps1` and setup quietly (see [When they run](#when-they-run)). You can run it too. |
| `update.ps1` | Shows the dev-home-tools commits waiting on GitHub, and installs them after a yes. With `-Quiet`, as a sync runs it, it never asks: it reports what's waiting, and installs it only when `autoUpdate` is on. |

### When they run

Nothing runs on a schedule. Each script runs only when you or an agent starts it.

| Script | When it runs |
| --- | --- |
| `sync.ps1` | In Claude Code, agents run it at the start of every `/handoff` command, for a plain `/knowledge`, and before adding to the knowledge base; that sync also runs `update.ps1` and setup. Then they run it again to commit and push each change they make. That second sync skips the update check, and runs setup only if it brought in commits from GitHub, because the sync just before it did both. A lookup, `/knowledge <question>`, never syncs, and Codex never runs it. You can run it any time. |
| `update.ps1` | Each sync that isn't committing runs it quietly, to check for updates. You run it yourself to look at an update and install it, when `autoUpdate` is off (see [Updates](#updates)). |
| `setup.ps1` | You run it once per PC, and again to change a setting or to say yes to a settings change. After that, syncs run it quietly, as above, and so does `update.ps1` after you install an update. That quiet run never asks anything, and never changes Claude Code's or Codex's settings. |

### What they report

Agents pass on what `sync.ps1` reports:

| Word | Meaning |
| --- | --- |
| `OK` | Up to date, or nothing to do. |
| `COMMITTED` | Committed the files it was given. |
| `PULLED`, `MERGED` | Brought in commits from GitHub. `MERGED` means two PCs both had new commits. |
| `PUSHED` | Sent this PC's commits to GitHub. |
| `PENDING` | Commits not pushed yet. The next sync pushes them. |
| `OFFLINE` | GitHub couldn't be reached. The line says for which repo: your dev-home may be behind, or dev-home-tools wasn't checked for updates. |
| `LEFT` | A file changed recently and isn't committed. Another session may be working on it. |
| `STALE` | An uncommitted file nobody has touched for 15 minutes. The agent asks whether to commit and push it. |
| `UPDATE` | New dev-home-tools commits are waiting. |
| `PROBLEM` | Needs you. The message says what to do. |

Setup's lines, such as `LINKED` or `WROTE`, say what it changed on this PC.

## What setup changes on your PC

Setup doesn't copy the skills and rules into Claude Code's and Codex's folders. It adds links
there instead: a link is a folder entry that points to a folder somewhere else, and the tools
read through it as if the files were right there. So when a sync or an update changes a skill
or a rule, the tools see the change at once, with nothing to copy. Setup makes folder links as
directory junctions, or as symbolic links when Windows Developer Mode is on; neither needs admin
rights.

- **In your dev-home-tools folder,** two things that belong to this PC only. Git ignores both, so
  they never go to GitHub, and an update never overwrites them.
  - `.generated/`: this PC's copy of the skills and operating rules, at the same paths they have
    under `templates/`. In this repo, they hold a placeholder wherever a folder path goes,
    because everyone keeps their folders in different places. Setup writes a copy with this PC's
    real paths filled in, and that copy is what the tools use. The paths have to be written out
    in full, because the commands a skill may run without asking you are matched by their exact
    text. Setup rewrites this folder whenever it runs, so don't edit it; put skills of your own
    in your dev-home.
  - `local-settings.json`: this PC's answers to setup's questions: where your dev-home is,
    whether to install updates automatically, and which extra Claude Code folders to set up.
    The scripts read it to find your dev-home.
- **In each Claude Code folder** (`~\.claude`, plus any extra ones):
  - Links in `skills\` to each skill (this repo's, and your own from dev-home). In `rules\`,
    `dev-home-operating-rules` links to the operating rules, and `dev-home-global-rules` to your
    dev-home's `global-rules\`. Nothing in that folder says which repo a name belongs to, so
    each link starts with `dev-home-`.
  - After your yes, `settings.json` gets your dev-home and dev-home-tools folders in
    `permissions.additionalDirectories`, so Claude Code can use them from any project.
  - Your own `CLAUDE.md` there is never touched.
- **For Codex,** when `~\.codex` exists:
  - Links in `~\.agents\skills\`.
  - `~\.codex\AGENTS.md`, the operating rules and your global rules joined into one file,
    because Codex reads only one always-on file. Setup rewrites it whenever it runs, but never
    replaces an `AGENTS.md` it didn't write.
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

- **Your project repos are treated as public.** The operating rules tell agents never to quote
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
- **Edit your global rules in dev-home,** in `global-rules/global-rules.md`, never in
  `~\.codex\AGENTS.md`, which setup rewrites.
- If PowerShell says a script isn't digitally signed (after downloading this repo as a zip, for
  example), run `Unblock-File <script>` once.

## Troubleshooting

- **Setup ends with "problem(s) to fix".** Each `PROBLEM` line says what to do. Fix those, then
  run setup again.
- **`/handoff` says the operating rules aren't loaded.** Restart the agent. If it still says so,
  run setup and read its output. In the Claude desktop app's Cowork sessions, Claude Code skips
  rule folders linked from outside the session's folder, so the rules may not load there.
- **A skill seems to be missing.** Run setup with `-Quiet`, then restart the agent.
- **Setup reports a dev-home repo with no commits.** A setup run stopped partway through
  creating it, for example because git didn't know your name yet. If that folder holds nothing
  you need, delete it, fix the cause, and run setup again.

## Working on dev-home-tools

| Path | What it is |
| --- | --- |
| `setup.ps1`, `sync.ps1`, `update.ps1` | The scripts (see [The scripts](#the-scripts)). |
| `templates/` | Everything setup fills in with each PC's paths. |
| `templates/operating-rules/` | The operating rules every session loads, along with your global rules. Filled in on every setup run, into `.generated/`. |
| `templates/skills/` | The skills, one folder each. Filled in on every setup run, into `.generated/`. |
| `templates/dev-home-starter/` | The files a brand-new dev-home starts with. Filled in once, when setup creates it. |
| `internal/` | dev-home-tools' own machinery, which nobody runs directly. |
| `internal/shared/` | What the three scripts share, one file per job: `git.ps1` runs git, and `output.ps1` prints status lines. |
| `internal/tests/` | The test runner. |

[AGENTS.md](AGENTS.md) has the rules for changing this repo, for people and agents alike. Before
committing, run:

```powershell
pwsh -NoProfile -File internal/tests/Invoke-Tests.ps1
```

It tests the working tree in throwaway copies under `.test-sandbox/`, never your real profile or
dev-home, and needs no network. Never point this folder's scripts at a test dev-home: they would
rewrite the files your real links depend on.

## License

MIT. See [LICENSE](LICENSE).
