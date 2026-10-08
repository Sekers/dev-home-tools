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
  `{{PYTHON}} -I {{TOOLS_DIR}}/setup.py --quiet`, then try again.
- Treat my project repos as public. In their files, commits, PRs, and issues, never quote
  dev-home, paraphrase its notes, or mention that it exists. The only exceptions are a skill's
  steps that have me approve the exact words first, and even those never name dev-home.
- Knowledge candidate: only a general finding we checked this session (a test or the docs), or
  a pitfall agents keep hitting in my setup with a checked fix, worth its token cost. General:
  it would help any project using the same tool, library, or service, even one of mine, and
  names no tenant or private detail. Offer `Knowledge candidate: <folder/file>: <what>.
  Evidence: <what we ran or read>. Add it, commit, and push?` For a normal docs item of a project
  whose docs I can change, replace that last question with `It may belong in <project>'s docs
  instead. Docs, or add it to the knowledge base, commit, and push?` Most sessions have none;
  don't re-offer a no.
- Findings that only help work on one project's own code go where that project's AGENTS.md says
  research goes. Anything about a project that shouldn't be public goes in its handoff.
- My global rules in `{{CONTENT_DIR}}/global-rules/global-rules.md` add to these, and win where
  the two conflict.
