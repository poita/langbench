"""Splitting a content file into its TOML front matter and Markdown body."""

from __future__ import annotations

from . import toml
from .errors import ContentError

_FENCE = "+++"


def split_front_matter(text: str) -> tuple[str, str]:
    """Split *text* into ``(front matter text, body)``.

    The file must start with a ``+++`` line; the front matter ends at the
    next line that is exactly ``+++``.  The body is everything after that
    line's newline, verbatim.
    """
    if not text.startswith(_FENCE + "\n"):
        raise ContentError("content file does not start with a '+++' line")
    start = len(_FENCE) + 1
    pos = start
    size = len(text)
    while pos <= size:
        eol = text.find("\n", pos)
        end = size if eol == -1 else eol
        if text[pos:end] == _FENCE:
            return text[start:pos], "" if eol == -1 else text[eol + 1 :]
        if eol == -1:
            break
        pos = eol + 1
    raise ContentError("front matter is not closed by a '+++' line")


def parse_front_matter(text: str) -> tuple[dict[str, toml.TomlValue], str]:
    """Split *text* and parse its front matter: ``(metadata, body)``."""
    raw, body = split_front_matter(text)
    return toml.loads(raw), body
