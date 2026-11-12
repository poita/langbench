"""Reading a site source directory."""

from __future__ import annotations

import os
from dataclasses import dataclass, field

from . import toml
from .content import Page, Post, parse_page, parse_post
from .errors import ContentError

_REQUIRED_SITE_KEYS = {"title": str, "base_url": str, "author": str, "posts_per_page": int}


@dataclass
class Source:
    """Everything read from a site source directory."""

    site: dict[str, toml.TomlValue]
    posts: list[Post] = field(default_factory=list)
    pages: list[Page] = field(default_factory=list)
    templates: dict[str, str] = field(default_factory=dict)
    static_dir: str | None = None


def read_text(path: str) -> str:
    """Read a UTF-8 file without any newline translation."""
    with open(path, "rb") as handle:
        return handle.read().decode("utf-8")


def _files(directory: str, suffix: str) -> list[tuple[str, str]]:
    """``(name, path)`` of the regular files directly in *directory*."""
    try:
        entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
    except FileNotFoundError:
        return []
    return [(e.name, e.path) for e in entries if e.name.endswith(suffix) and e.is_file()]


def parse_site_config(text: str) -> dict[str, toml.TomlValue]:
    """Parse and validate the text of ``site.toml``."""
    site = toml.loads(text)
    for key, kind in _REQUIRED_SITE_KEYS.items():
        if type(site.get(key)) is not kind:
            raise ContentError(f"site.toml: {key!r} must be a {kind.__name__}")
    if site["posts_per_page"] < 1:
        raise ContentError("site.toml: 'posts_per_page' must be at least 1")
    return site


def read_source(root: str) -> Source:
    """Read the site source directory *root*."""
    site = parse_site_config(read_text(os.path.join(root, "site.toml")))
    source = Source(site)
    for name, path in _files(os.path.join(root, "content", "posts"), ".md"):
        source.posts.append(parse_post(name, read_text(path)))
    for name, path in _files(os.path.join(root, "content", "pages"), ".md"):
        source.pages.append(parse_page(name, read_text(path)))
    for name, path in _files(os.path.join(root, "templates"), ".html"):
        text = read_text(path)
        source.templates[name] = text[:-1] if text.endswith("\n") else text
    static = os.path.join(root, "static")
    if os.path.isdir(static):
        source.static_dir = static
    return source
