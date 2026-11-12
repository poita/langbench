"""Content objects (posts and pages) and the small helpers around them."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .errors import ContentError
from .frontmatter import parse_front_matter

_MONTHS = (
    "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December",
)
_DATE = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})")
_NON_SLUG = re.compile(r"[^a-z0-9]+")


@dataclass(frozen=True)
class Post:
    """A post as written in ``content/posts``."""

    title: str
    date: str
    slug: str
    body: str
    tags: tuple[str, ...] = ()
    draft: bool = False


@dataclass(frozen=True)
class Page:
    """A page as written in ``content/pages``."""

    title: str
    slug: str
    body: str
    draft: bool = False


def tag_slug(name: str) -> str:
    """The URL slug of a tag name.

    ASCII letters are lower-cased, every run of other characters becomes a
    single ``-``, and leading and trailing ``-`` are removed.

    >>> tag_slug("Web Development"), tag_slug("C++"), tag_slug("Rust 2024")
    ('web-development', 'c', 'rust-2024')
    """
    lowered = "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in name)
    return _NON_SLUG.sub("-", lowered).strip("-")


def long_date(date: str) -> str:
    """Format ``YYYY-MM-DD`` as ``<Month> <D>, <YYYY>``.

    >>> long_date("2024-03-05")
    'March 5, 2024'
    """
    match = _DATE.fullmatch(date)
    if match is None or not 1 <= int(match.group(2)) <= 12:
        raise ContentError(f"invalid date {date!r}")
    return f"{_MONTHS[int(match.group(2)) - 1]} {int(match.group(3))}, {match.group(1)}"


def first_block(body: str) -> str:
    """The text of a body's first block: its first run of non-blank lines.

    Leading blank lines are skipped; the following maximal run of non-blank
    lines is returned joined by LF.  A blank body gives ``""``.
    """
    lines = body.split("\n")
    start = 0
    while start < len(lines) and not lines[start].strip(" \t"):
        start += 1
    end = start
    while end < len(lines) and lines[end].strip(" \t"):
        end += 1
    return "\n".join(lines[start:end])


def _require(meta: dict, key: str, kind: type, filename: str):
    value = meta.get(key)
    if type(value) is not kind:
        raise ContentError(f"{filename}: front matter key {key!r} must be a {kind.__name__}")
    return value


def _optional(meta: dict, key: str, kind: type, default, filename: str):
    if key not in meta:
        return default
    return _require(meta, key, kind, filename)


def _default_slug(filename: str) -> str:
    return filename[: -len(".md")] if filename.endswith(".md") else filename


def parse_post(filename: str, text: str) -> Post:
    """Parse the content of the post file *filename*."""
    meta, body = parse_front_matter(text)
    tags = _optional(meta, "tags", list, [], filename)
    return Post(
        title=_require(meta, "title", str, filename),
        date=_require(meta, "date", str, filename),
        slug=_optional(meta, "slug", str, _default_slug(filename), filename),
        body=body,
        tags=tuple(tags),
        draft=_optional(meta, "draft", bool, False, filename),
    )


def parse_page(filename: str, text: str) -> Page:
    """Parse the content of the page file *filename*."""
    meta, body = parse_front_matter(text)
    return Page(
        title=_require(meta, "title", str, filename),
        slug=_optional(meta, "slug", str, _default_slug(filename), filename),
        body=body,
        draft=_optional(meta, "draft", bool, False, filename),
    )
