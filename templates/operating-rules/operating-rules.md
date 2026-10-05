# Private repo: dev-home (rules loaded)

- `{{CONTENT_DIR}}` is my private repo, dev-home. It holds project handoffs and my general
  knowledge base. Use the `handoff` and `knowledge` skills for them.
- Other sessions share dev-home. Run git there only through
  `{{PYTHON}} -I {{TOOLS_DIR}}/sync.py`, and never stage, commit, stash, or discard a file you
  didn't change.
- Project status belongs in the handoff, and lasting decisions in the project's own files, never
  in auto memory.
- Create new personal skills in `{{CONTENT_DIR}}/skills/`, never in a tool's own skills folder,
  so every PC gets them. If a skill seems to be missing, run
  `pwsh -NoProfile -File {{TOOLS_DIR}}/setup.ps1 -Quiet`, then try again.
- Treat my project repos as public. In their files, commits, PRs, and issues, never quote
  dev-home, paraphrase its notes, or mention that it exists. The only exceptions are a skill's
  steps that have me approve the exact words first, and even those never name dev-home.
- Knowledge candidate: only a general finding we checked this session (a test or the docs), or
  a pitfall agents keep hitting in my setup with a checked fix, worth its token cost and naming
  none of my functions, files, or tenants. Offer "Knowledge candidate: <folder/file>: <what>.
  Evidence: <what we ran or read>. Add it, commit, and push?" Most sessions have none; don't
  re-offer a no.
- Findings specific to one project go where that project's AGENTS.md says research goes.
  Anything about a project that shouldn't be public goes in its handoff.
- My global rules in `{{CONTENT_DIR}}/global-rules/global-rules.md` add to these, and win where
  the two conflict.
