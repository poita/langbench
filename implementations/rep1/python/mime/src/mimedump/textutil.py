"""Small text and byte helpers shared by the other modules."""

from __future__ import annotations

import re

#: ``str.translate`` table that lower-cases ASCII letters only.
_ASCII_LOWER = {c: c + 32 for c in range(ord("A"), ord("Z") + 1)}

_BLANK_RUN = re.compile(r"[ \t]+")


def ascii_lower(s: str) -> str:
    """Lower-case the ASCII letters of *s*, leaving every other character alone."""
    return s.translate(_ASCII_LOWER)


def strip_blanks(s: str) -> str:
    """Strip leading and trailing SPACE and TAB characters."""
    return s.strip(" \t")


def collapse(s: str) -> str:
    """Replace each run of SPACE/TAB by one SPACE and strip the ends."""
    return _BLANK_RUN.sub(" ", s).strip(" ")


def normalize_newlines(data: bytes) -> bytes:
    """Turn every CRLF into a single LF; nothing else changes."""
    return data.replace(b"\r\n", b"\n")
