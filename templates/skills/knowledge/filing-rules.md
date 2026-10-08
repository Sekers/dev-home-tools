# Knowledge base filing rules

The rules for every file in the knowledge base. The index is `README.md` in the knowledge folder;
these rules live with the skill, so they update with dev-home-tools.

## Layout

- One folder per subject, named for the system, library, or service the facts describe, such as
  `powershell`, `git-and-github`, `windows`, `python`, or `ai-agents`.
- One file per topic.

## Names

- Lowercase letters, digits, and hyphens.
- The folder is the subject and the file is the topic, so don't repeat the subject in the file
  name.
- Nouns for reference (`pipeline-binding.md`). Verb first for how-tos (`sign-commits-with-gpg.md`).
- No filler words: behavior, notes, misc, general.
- No dates or versions in names.

## How every file starts

~~~markdown
# Subject: topic

**Covers:** what the file answers.
**Last verified:** YYYY-MM-DD, with the versions it was checked on.
**Summary:** the takeaway in one line.
~~~

Add **Doesn't cover:** when the topic is easy to confuse with another, and **Origin:** when it
helps to know where a finding came from.

## Evidence labels

Every section carries one, with its own date and versions:

- **Measured:** run and observed.
- **From documentation:** with the page linked.
- **From source:** read in the upstream code, linked.
- **Observed:** agents hit this pitfall, with dates and how we know it recurs. The fix still
  needs one of the labels above.
- **Unverified:** an assumption or a secondhand report, labeled as such.

## When facts change

- Re-checked one section: update that section's date and versions. Change the file's
  **Last verified** only when you re-checked the whole file.
- Behavior differs by version: keep both, with version numbers, for example "7.4 does X;
  7.5 and later do Y".
- Otherwise, replace the old fact and re-date it. Git history keeps the old version.

## The index

- One row per file, each on a single line, in the table in `README.md`. Git merges that file
  line by line, so rows added on two PCs combine.
- Adding, renaming, or splitting a file updates the index in the same commit.

## Content

- The general test: it helps any project that uses the same language, platform, tool, library,
  or service, whoever makes it, your own included, and it names no tenant, personal path, or
  other private detail. Judge the fact, not the project where it came up. What only helps work
  on one project's own code stays in that project. Anything that fails the test stays out of the
  knowledge base.
- Worth its cost: the index is read on every lookup, and a file is read whole when it's opened.
  Keep entries short, add to an existing file before creating one, and remove what no longer
  earns its place.
- One home per fact. Link to it instead of copying it.
- Split a file when it answers two unrelated questions or passes about 20 KB.
- Fast-moving subjects such as `ai-agents`: re-check anything older than about three months
  before relying on it.
- Never: secrets, credentials, tenant or account IDs, or personal information about anyone other
  than you, such as customer or colleague data.
