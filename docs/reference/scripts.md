# The scripts

| Script | What it's for |
| --- | --- |
| `setup.py` | Sets up this PC. Safe to run any number of times. `--what-if` previews; `--quiet` prints only changes and problems, and never asks (agents run it this way); `--content-dir <folder>` points it at a different dev-home. |
| `sync.py` | Syncs your dev-home with GitHub, and commits only the files it's given. Agents run all their git in dev-home through it. Then it checks for updates as `update.py` does, and runs setup quietly (see [When they run](#when-they-run)). You can run it too; `--help` says how to commit with it. |
| `update.py` | Shows the dev-home-tools commits waiting on GitHub, and installs them after a yes. With `--quiet`, as a sync runs it, it never asks: it reports what's waiting, and installs it only when `autoUpdate` is on. |

All three are Python. Run them with the Python install manager's `py`, such as
`py C:\Programming\dev-home-tools\setup.py`. Each is a short entry point that loads its code from
`internal/shared/`, and `--help` says what it does.

The skills also run two Python scripts of their own, which only agents run, from
`templates/shared-skill-scripts/`: `prepare.py` starts each skill command that syncs, by running
the sync inside its own process and then reporting what the skill needs, such as where the
project's handoff is; and `facts.py` reports that alone, which is how the handoff skill starts in
Codex.

## When they run

Nothing runs on a schedule. Each script runs only when you or an agent starts it.

| Script | When it runs |
| --- | --- |
| `sync.py` | In Claude Code, agents run it at the start of every `/handoff` command, for a plain `/knowledge`, and before adding to the knowledge base, through the skills' `prepare.py`; that sync also checks for updates and runs setup. Then they run it again to commit and push each change they make. That second sync skips the update check, and runs setup only if it brought in commits from GitHub, because the sync just before it did both. A lookup, `/knowledge <question>`, never syncs, and Codex never runs it. You can run it any time. |
| `update.py` | Each sync that isn't committing runs its check, quietly. You run it yourself to look at an update and install it, when `autoUpdate` is off (see [Updates](#updates)). |
| `setup.py` | You run it once per PC, and again to change a setting, to answer a question it hasn't asked yet, or to say yes to a settings change. After that, syncs run it quietly, as above, and so does `update.py` after you install an update. That quiet run never asks anything, and never changes Claude Code's or Codex's settings. |

## What they report

Agents pass on what `sync.py` reports, and `prepare.py` with it:

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
| `RELOAD` | From `prepare.py`: the skill has changed since the session loaded it, such as after an update, so the agent stops. Type the skill's command again to load its new steps. |

Setup's lines, such as `LINKED` or `WROTE`, say what it changed on this PC.

## Updates

Your copy of dev-home-tools never changes by itself. Instead, each sync that isn't committing a
change, such as the one every `/handoff` starts with, checks GitHub for new commits to
dev-home-tools. What happens when some are waiting depends on your answer to setup's question
about `autoUpdate`:

| `autoUpdate` | When new commits are waiting | What you do |
| --- | --- | --- |
| Off (the default, and until you answer) | Nothing is installed, and the agent tells you an update is waiting. | When you're ready, run `update.py` (below). It lists the commits and the files they change, and installs them only if you answer `y`. |
| On | The sync installs them, and the agent tells you it did. | Nothing. |

```powershell
py C:\Programming\dev-home-tools\update.py
```

Either way, `update.py`'s code does the work: the sync runs it quietly, and you run it yourself
to look first. So an update is always installed the same way:

- **It only moves your copy forward to GitHub's version.** It never merges, so if you've made
  commits of your own in your dev-home-tools folder, nothing is installed, and the agent says
  so: pull and merge the update yourself with git. A change you haven't committed is never
  overwritten either: an update that touches the same file waits until it's gone.
- **Setup runs afterwards,** so the new skills and rules take effect.
- **It changes only your dev-home-tools folder.** Your dev-home and everything in it stay as
  they are.

To switch `autoUpdate`, set it to `true` or `false` in `local-settings.json`, in your
dev-home-tools folder.
