# dev-home

My private repo for AI-agent handoffs and a general knowledge base, kept on GitHub with its full
history as a backup, and shared by my PCs when I use more than one. My public project repos never
reference it.

The tooling that works with it lives in dev-home-tools, at `{{TOOLS_DIR}}`. Its README covers
setup, a typical day, and safety, and lists the rest of its docs.

| Path | What it is |
| --- | --- |
| `handoffs/<service>/<project path>/HANDOFF.md` | Private session state for one project, filed by where it's hosted, such as `handoffs/github/you/tool/`. Projects hosted elsewhere go in `handoffs/other/`, and projects with no remote in `handoffs/local/`, by folder name and first commit. Read and updated with `/handoff`. |
| `knowledge/` | General knowledge for coding and AI work. `knowledge/README.md` is the index. |
| `global-rules/global-rules.md` | My global rules: my own always-on preferences for every project, loaded in every session along with the operating rules from dev-home-tools. |
| `skills/` | My personal skills, if any. Setup links them into Claude Code and Codex. |
| `dev-home.json` | Settings every copy of this repo shares. `multiMachine` is `false` while one copy is in active use, so a sync checks GitHub only every few hours, and `true` once more are, so each command checks first. Setup asks, and commits the answer. |
| `AGENTS.md` | Rules for an agent working inside this repo. |
| `.drafts/` | Scratch space for text that leaves this repo, such as GitHub issue bodies. Git ignores it. |
