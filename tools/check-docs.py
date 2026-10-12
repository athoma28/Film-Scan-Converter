#!/usr/bin/env python3
"""Check public documentation links and navigation without third-party packages.

Run from any directory. This validates repository targets, Markdown heading
anchors, and the simple list-form nav used by mkdocs.yml. It does not request
external URLs or validate shell commands, research results, or rendered layout.
"""

from __future__ import annotations

import argparse
import re
import unicodedata
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


REPOSITORY_URL = "https://github.com/athoma28/Film-Scan-Converter/"
PRIVATE_ROOTS = {"dist", "sample-raw"}
LINK = re.compile(
    r'!?\[[^\]\n]*\]\(\s*(?:<([^>]+)>|([^\s)]+))'
    r'(?:\s+[\"\'][^\n]*?[\"\'])?\s*\)'
)
REFERENCE = re.compile(r"^ {0,3}\[[^\]]+\]:\s*<?([^\s>]+)>?", re.MULTILINE)
HEADING = re.compile(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$", re.MULTILINE)


def prose(text: str) -> str:
    """Hide fenced code while retaining line numbers for diagnostics."""
    lines = []
    fence = None
    for line in text.splitlines(keepends=True):
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker and fence is None:
            fence = marker.group(1)
        elif marker and fence and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= len(fence):
            fence = None
            lines.append("\n" if line.endswith("\n") else "")
            continue
        if fence:
            lines.append("\n" if line.endswith("\n") else "")
        else:
            lines.append(line)
    return re.sub(
        r"<!--[\s\S]*?-->",
        lambda match: re.sub(r"[^\n]", " ", match.group()),
        "".join(lines),
    )


def without_inline_code(text: str) -> str:
    return re.sub(
        r"(?<!`)(`+)(?!`)([\s\S]*?)(?<!`)\1(?!`)",
        lambda match: re.sub(r"[^\n]", " ", match.group()),
        text,
    )


class HTMLAnchors(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.ids: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for name, value in attrs:
            if value and (name == "id" or (tag == "a" and name == "name")):
                self.ids.add(value)


def anchors(text: str, github: bool = False) -> set[str]:
    text = prose(text)
    parser = HTMLAnchors()
    parser.feed(without_inline_code(text))
    result = parser.ids
    counts: dict[str, int] = {}
    for match in HEADING.finditer(text):
        label = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", match.group(1))
        label = re.sub(r"<[^>]*>", "", label).lower()
        if not github:
            # MkDocs' default TOC slugifier uses ASCII normalized text.
            label = unicodedata.normalize("NFKD", label).encode("ascii", "ignore").decode()
        label = re.sub(r"[^\w\s-]", "", label).strip()
        base = re.sub(r"[-\s]+", "-", label)
        number = counts.get(base, 0)
        separator = "-" if github else "_"
        result.add(base if number == 0 else f"{base}{separator}{number}")
        counts[base] = number + 1
    return result


def public_pages(root: Path) -> list[Path]:
    pages = list(root.glob("*.md")) + list((root / "docs").rglob("*.md"))
    pages += [root / path for path in ("native/README.md", "native/diagnostics/README.md", "tests/README.md")]
    return sorted({page.resolve() for page in pages if page.is_file()})


def local_target(root: Path, page: Path, url: str) -> tuple[Path, str] | None:
    parsed = urlsplit(url)
    if url.startswith(REPOSITORY_URL):
        tail = unquote(parsed.path).split("/Film-Scan-Converter/", 1)[1]
        # Only main-branch source links are checked against this checkout.
        if tail.startswith(("blob/main/", "tree/main/")):
            return root / tail.split("/", 2)[2], unquote(parsed.fragment)
        return None
    if parsed.scheme or parsed.netloc:
        return None
    path = unquote(parsed.path)
    target = root / path.lstrip("/") if path.startswith("/") else page.parent / path
    return (target if path else page).resolve(), unquote(parsed.fragment)


def navigation(root: Path) -> list[str]:
    """Read Markdown page scalars in this repository's list-form YAML nav."""
    paths = []
    active = False
    for line in (root / "mkdocs.yml").read_text().splitlines():
        if line == "nav:":
            active = True
            continue
        if active and line and not line[0].isspace() and not line.startswith("#"):
            break
        if active:
            match = re.match(r"^\s+-\s+[^:]+:\s*([\"\']?)([^\"\']+\.md)\1\s*$", line)
            if match:
                paths.append(match.group(2))
    return paths


def check(root: Path) -> tuple[list[str], int, int]:
    root = root.resolve()
    errors = []
    pages = public_pages(root)
    links = 0
    heading_cache: dict[tuple[Path, bool], set[str]] = {}
    graph: dict[Path, set[Path]] = {}
    for page in pages:
        text = without_inline_code(prose(page.read_text()))
        matches = [(m.start(), m.group(1) or m.group(2)) for m in LINK.finditer(text)]
        matches += [(m.start(), m.group(1)) for m in REFERENCE.finditer(text)]
        graph[page] = set()
        for offset, url in matches:
            links += 1
            location = f"{page.relative_to(root)}:{text.count(chr(10), 0, offset) + 1}"
            resolved = local_target(root, page, url)
            if resolved is None:
                continue
            target, fragment = resolved
            try:
                relative = target.relative_to(root)
            except ValueError:
                errors.append(f"{location}: link escapes repository: {url}")
                continue
            if relative.parts and relative.parts[0] in PRIVATE_ROOTS:
                errors.append(f"{location}: private artifact hyperlink; use a literal code path: {url}")
                continue
            if not target.exists():
                errors.append(f"{location}: missing target: {url}")
                continue
            if page.is_relative_to(root / "docs") and not urlsplit(url).scheme and not target.is_relative_to(root / "docs"):
                errors.append(f"{location}: repository link outside published docs; use a GitHub source URL: {url}")
                continue
            if target.suffix == ".md":
                graph[page].add(target)
                if fragment:
                    key = (target, url.startswith(REPOSITORY_URL))
                    if key not in heading_cache:
                        heading_cache[key] = anchors(target.read_text(), github=key[1])
                    if fragment not in heading_cache[key]:
                        errors.append(f"{location}: missing heading anchor: {url}")

    nav = navigation(root)
    if not nav:
        errors.append("mkdocs.yml: no page entries found in list-form navigation")
    reachable = set()
    pending = [(root / "docs" / path).resolve() for path in nav]
    for path in pending:
        if not path.is_file():
            errors.append(f"mkdocs.yml: missing navigation page: {path.relative_to(root)}")
    while pending:
        page = pending.pop()
        if page in reachable:
            continue
        reachable.add(page)
        pending.extend(graph.get(page, set()) - reachable)
    for page in pages:
        if page.is_relative_to(root / "docs") and page not in reachable:
            errors.append(f"{page.relative_to(root)}: unreachable from MkDocs navigation")
    return errors, len(pages), links


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    errors, pages, links = check(root)
    for error in errors:
        print(error)
    print(f"Checked {pages} public Markdown pages and {links} links: {len(errors)} error(s).")
    print("External URL availability, command behavior, and rendered layout are not checked.")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
