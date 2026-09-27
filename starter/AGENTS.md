# dev-home: guidance for AI agents

This is my private repo for project handoffs and a general knowledge base, shared by my PCs
through GitHub. The tooling that works with it (the skills, the always-on core rules, setup.ps1,
and sync.ps1) lives in my clone of dev-home-tools, at `{{TOOLS_DIR}}`.

## Privacy

- This repo is private. Treat my project repos as public.
- Never copy, quote, paraphrase, or mention anything from this repo in a project's files,
  commits, PRs, or issues. The one exception is an issue I approve word for word through the
  handoff skill's `issue` command, and even that never mentions this repo.
- No secrets, credentials, tenant or account IDs, or personal information about anyone other
  than me, anywhere here. Say where a secret is kept, never its value.

## What's here

- `handoffs/<service>/<project path>/HANDOFF.md`: one per project, filed by where it's hosted,
  such as `handoffs/github/you/tool/`. Projects hosted elsewhere go under `handoffs/other/`,
  and projects with no remote under `handoffs/local/`, by folder name and first commit. The
  handoff skill finds, reads, and updates them.
- `knowledge/`: my general knowledge base. `knowledge/README.md` is its index; the rules for
  files come with the knowledge skill.
- `instructions/global.md`: my own always-on rules. Every session loads them after the core
  rules from dev-home-tools. Keep the file short: every line costs tokens in every session.
- `skills/`: my personal skills, if any. Setup links them into Claude Code and Codex.
- `.drafts/`: git-ignored scratch space for text that leaves this repo, such as GitHub issue
  bodies. Nothing in it is ever committed.

## Personal skills (skills/)

- Frontmatter uses only standard fields: `name`, `description`, and `allowed-tools`. The name
  matches the folder name.
- After adding, renaming, or removing one, run
  `pwsh -NoProfile -File {{TOOLS_DIR}}/setup.ps1 -Quiet`.

## Git

- Sessions in several projects, and Codex, use this repo at the same time, so a file you didn't
  change may be someone's work in progress. Never stage, commit, stash, reset, or discard it.
- Run git here only through `pwsh -NoProfile -File {{TOOLS_DIR}}/sync.ps1`. It syncs with
  GitHub; add `-Message "<area>: <what>"` and the paths to commit exactly those paths first.
  Show its `PROBLEM` lines to me.
- Never delete a lock file such as `.git/index.lock`. If sync.ps1 says git stayed busy, ask me.
- Commit messages read `<area>: <what>`, for example `handoff: you/tool` or
  `knowledge: powershell/pipeline-binding`.
- Commit signing is turned off in this repo's own config on purpose, because agents commit here
  unattended. That is not bypassing signing; my project repos keep signing.
