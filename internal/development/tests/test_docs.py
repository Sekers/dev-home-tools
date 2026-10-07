"""README.md and docs/, read without running anything: links, headings, and the pages for skills."""

import re
from pathlib import Path

from helpers import REPO_ROOT

DOCS = REPO_ROOT / "docs"
SKILLS = REPO_ROOT / "templates" / "skills"


def markdown_links(lines: list[str]) -> list[str]:
    """The target of each link in Markdown text, which is what's between the parentheses of
    [text](target). Leaves out code, where a link is only an example, and links to the web."""
    targets: list[str] = []
    in_code = False
    for line in lines:
        if re.match(r"\s*```", line):
            in_code = not in_code
            continue
        if in_code:
            continue
        for match in re.finditer(r"\]\(([^)\s]+)\)", re.sub(r"`[^`]*`", "", line)):
            target = match.group(1)
            if not re.match(r"[a-z][a-z0-9+.-]*:", target, re.IGNORECASE):
                targets.append(target)
    return targets


def markdown_anchors(lines: list[str]) -> list[str]:
    """The anchor GitHub gives each heading: lower case, punctuation dropped, and a hyphen for
    each space."""
    anchors: list[str] = []
    in_code = False
    for line in lines:
        if re.match(r"\s*```", line):
            in_code = not in_code
            continue
        if in_code:
            continue
        heading = re.match(r"#{1,6}\s+(.+?)\s*$", line)
        if heading:
            anchors.append(re.sub(r"[^a-z0-9 _-]", "", heading.group(1).lower()).replace(" ", "-"))
    return anchors


def lines_of(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines()


# Raw HTML as CommonMark defines it: an open tag, with any attributes, or a closing tag. GitHub
# hides it, so <what we ran or read> vanishes from the page. Anything else in angle brackets
# shows as written, such as <folder/file>, an autolink, or a comment.
ATTRIBUTE = r"""\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?"""
HTML_TAG = re.compile(rf"<[A-Za-z][A-Za-z0-9-]*(?:{ATTRIBUTE})*\s*/?>|</[A-Za-z][A-Za-z0-9-]*\s*>")
# A code span ends at the next run of exactly as many backticks, which may be on a later line of
# the same paragraph.
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)", re.DOTALL)


def html_tags(lines: list[str]) -> list[tuple[int, str]]:
    """Each piece of text that renders as an HTML tag, with its line number, outside code: fenced
    blocks, code spans, and a skill's frontmatter, which isn't rendered as Markdown. Lines are
    taken a paragraph at a time, so a code span can carry on to the next line."""
    found: list[tuple[int, str]] = []
    start = 0
    if lines and lines[0].strip() == "---":
        start = next((n + 1 for n in range(1, len(lines)) if lines[n].strip() == "---"), 0)
    paragraph: list[str] = []
    first = start
    in_code = False

    def check(text: str, at: int) -> None:
        # Blank out code spans and escaped brackets, keeping line breaks, so line numbers hold.
        text = CODE_SPAN.sub(lambda m: re.sub(r"[^\n]", " ", m.group()), text.replace("\\<", "  "))
        for match in HTML_TAG.finditer(text):
            found.append((at + text[: match.start()].count("\n") + 1, match.group()))

    for number in range(start, len(lines)):
        line = lines[number]
        if re.match(r"\s*(```|~~~)", line):
            check("\n".join(paragraph), first)
            paragraph = []
            in_code = not in_code
            continue
        if in_code:
            continue
        if not line.strip():
            check("\n".join(paragraph), first)
            paragraph = []
            continue
        if not paragraph:
            first = number
        paragraph.append(line)
    check("\n".join(paragraph), first)
    return found


def pages() -> list[Path]:
    return [REPO_ROOT / "README.md", *sorted(DOCS.rglob("*.md"))]


def linked_files(page: Path) -> list[tuple[str, Path, str]]:
    """Each link on a page: its target as written, the file it leads to, and its anchor."""
    found: list[tuple[str, Path, str]] = []
    for target in markdown_links(lines_of(page)):
        path, _, anchor = target.partition("#")
        file = (page.parent / path).resolve() if path else page
        found.append((target, file, anchor))
    return found


def name(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def test_the_link_search_finds_each_kind_and_nothing_in_code_or_on_the_web() -> None:
    sample = [
        "See [a page](docs/a.md), [a heading](#part-two), and [both](../b.md#top).",
        "Not `[code](docs/no.md)`, and not [the web](https://example.com/no.md).",
        "```",
        "[fenced](docs/no.md)",
        "```",
        "A link with [`code` as its text](c.md).",
    ]
    assert markdown_links(sample) == ["docs/a.md", "#part-two", "../b.md#top", "c.md"]


def test_the_tag_search_follows_commonmark_and_skips_code() -> None:
    sample = [
        "---",
        "description: <in frontmatter>",
        "---",
        "Offer <what we ran or read>, and </b> closes one.",
        "Not <folder/file>, <https://example.com>, <a@example.com>, <!-- a comment -->, or \\<x>.",
        "Not `<in a span>`, or `a span that goes on",
        "to the next line <name>`.",
        "```",
        "<fenced>",
        "```",
        "And <br/> on line 11.",
    ]
    assert html_tags(sample) == [(4, "<what we ran or read>"), (4, "</b>"), (11, "<br/>")]


def test_no_text_renders_as_an_html_tag() -> None:
    # GitHub would hide it. The handoff template is left out: agents copy it into new handoffs,
    # where code formatting could end up around text that isn't code.
    template = REPO_ROOT / "templates" / "skills" / "handoff" / "template.md"
    files = pages() + sorted(
        path for path in (REPO_ROOT / "templates").rglob("*.md") if path != template
    )
    found = [f"{name(path)}:{n}: {tag}" for path in files for n, tag in html_tags(lines_of(path))]
    assert found == []


def test_every_link_points_to_a_file_that_exists() -> None:
    missing = [f"{name(p)}: {t}" for p in pages() for t, f, _ in linked_files(p) if not f.exists()]
    assert len(pages()) > 1
    assert missing == []


def test_every_link_to_a_heading_points_to_one_that_exists() -> None:
    missing = [
        f"{name(page)}: {target}"
        for page in pages()
        for target, file, anchor in linked_files(page)
        if anchor and file.exists() and anchor not in markdown_anchors(lines_of(file))
    ]
    assert missing == []


def test_the_readme_links_to_every_page_under_docs() -> None:
    # The README's table is the only list of the pages, so a page it leaves out can't be found.
    from_readme = {file for _, file, _ in linked_files(REPO_ROOT / "README.md")}
    unlisted = [name(page) for page in pages()[1:] if page.resolve() not in from_readme]
    assert unlisted == []


def test_every_skill_has_a_page_and_every_page_a_skill() -> None:
    skills = sorted(folder.name for folder in SKILLS.iterdir() if folder.is_dir())
    skill_pages = sorted(page.stem for page in (DOCS / "skills").glob("*.md"))
    assert skills
    assert skills == skill_pages


def test_the_readme_links_to_each_skills_page_never_its_skill_file() -> None:
    # A skill's page is written for people and its SKILL.md for agents.
    from_readme = [name(file) for _, file, _ in linked_files(REPO_ROOT / "README.md")]
    assert [f for f in from_readme if f.endswith("/SKILL.md")] == []


def test_every_skills_page_links_to_its_skill_file() -> None:
    unlinked = []
    for skill in sorted(folder for folder in SKILLS.iterdir() if folder.is_dir()):
        page = DOCS / "skills" / f"{skill.name}.md"
        if not page.exists():
            continue
        linked = {file for _, file, _ in linked_files(page)}
        if (skill / "SKILL.md").resolve() not in linked:
            unlinked.append(skill.name)
    assert unlinked == []
