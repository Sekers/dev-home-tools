# What setup changes on your PC

Setup doesn't copy the skills and rules into Claude Code's and Codex's folders. It adds links
there instead: a link is a folder entry that points to a folder somewhere else, and the tools
read through it as if the files were right there. So when a sync or an update changes a skill
or a rule, the tools see the change at once, with nothing to copy. Setup makes folder links as
directory junctions, or as symbolic links when Windows Developer Mode is on; neither needs admin
rights.

- **In your dev-home-tools folder,** three things that belong to this PC only. Git ignores them,
  so they never go to GitHub, and an update never overwrites them.
  - `.generated/`: this PC's copy of the skills, the scripts they share, and the operating
    rules, at the same paths they have under `templates/`. In this repo, they hold a
    placeholder wherever a folder path goes, because everyone keeps their folders in different
    places. Setup writes a copy with this PC's
    real paths filled in, and that copy is what the tools use. The paths have to be written out
    in full, because the commands a skill may run without asking you are matched by their exact
    text. Setup rewrites this folder whenever it runs, so don't edit it; put skills of your own
    in your dev-home. Each skill's `SKILL.md` and the operating rules carry a note saying so,
    with the path of the template to change instead, because an agent working in another
    project sees only this copy. Python adds `__pycache__` folders beside the scripts when they
    run, so they start faster next time; setup leaves those alone.
  - `.python\`: a directory junction to the folder of the Python the skills' scripts run with,
    so every skill command can name `.python\python.exe` here: a short path, the same on every
    PC, with no spaces to quote. Setup looks first for the Python install manager's shortcuts,
    in `%LocalAppData%\Python\bin`, whose `python.exe` moves on to newer Pythons as you install
    them, and then for the newest Python 3.12 or later in the registry, which is where the
    traditional installer records one. It looks only when it makes the junction, or when the
    `python.exe` the junction leads to is gone; other runs just check that it's there. It
    always makes a junction here, even with Developer Mode on.
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

**To remove it all:** delete each link with `cmd /c rmdir <link>`, `.python` included, delete
`~\.codex\AGENTS.md`, take the added lines out of the settings files, then delete your
dev-home-tools folder. Your dev-home stays as it is.
