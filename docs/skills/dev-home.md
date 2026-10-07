# dev-home

These sync your dev-home with GitHub when you ask, and show and change dev-home-tools' settings.
The exact steps agents follow are in the skill itself:
[`SKILL.md`](../../templates/skills/dev-home/SKILL.md).

| Command | What it does |
| --- | --- |
| `/dev-home` | Lists these commands. It runs nothing, so typing the name alone never reaches GitHub. |
| `/dev-home sync` | Syncs your dev-home with GitHub now, however many copies are in use: brings in commits from your other copies, pushes this PC's, and lists the files left uncommitted. Like every sync, it also checks for dev-home-tools updates and runs setup quietly. |
| `/dev-home configure` | Shows every setting with its value, and changes one you choose. The agent shows you the exact change first, and makes it only after your yes. |
| `/dev-home configure <change>` | The same, starting from your change, such as `/dev-home configure check GitHub every 6 hours`. |

- **A sync commits nothing by itself.** For a file in your dev-home that nobody has touched for
  15 minutes, the agent asks whether to commit and push it. A file changed more recently may be
  another session's work in progress, so it's left alone unless you say it's yours. What the
  sync's status words mean is in [The scripts](../reference/scripts.md#what-they-report).
- **Settings change only through setup.** The agent runs `setup.py --configure` with the one
  setting you agreed on, such as `contentCheckHours=6`: first with `--what-if`, to show you the
  change, then for real after your yes. Setup checks the value, and keeps a dated backup of
  `local-settings.json`.
- **One setting is shared by every copy:** whether dev-home is in active use anywhere besides
  this PC. It's kept in your dev-home's `dev-home.json`, so a change to it is committed and
  pushed, and the agent's question says so. Before a switch to one copy, the agent asks whether
  your other copies are retired. After a switch to several, run `/dev-home sync` on each of the
  others.
- **In Codex, both commands change nothing,** for the same reason as
  [handoff commands](handoff.md): on Windows, git and `gh` can't use your GitHub credentials
  there. The agent gives you the command to run in a terminal instead.
