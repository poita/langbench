"""Workspace-path and phony-reference syntax."""

from __future__ import annotations

import re
from functools import lru_cache

__all__ = [
    "is_workspace_path",
    "is_phony_ref",
    "is_generated",
    "STATE_PATH",
    "BUILD_FILE",
]

STATE_PATH = b".kiln-state"
BUILD_FILE = b"main.kiln"

_PATH_RE = re.compile(rb"[A-Za-z0-9_.+\-]{1,255}(?:/[A-Za-z0-9_.+\-]{1,255})*")
_PHONY_RE = re.compile(rb"@[A-Za-z_][A-Za-z0-9_]*")


@lru_cache(maxsize=65536)
def is_workspace_path(path: bytes) -> bool:
    """True if ``path`` is a syntactically valid workspace path."""
    if len(path) > 1024 or _PATH_RE.fullmatch(path) is None:
        return False
    return not any(c == b"." or c == b".." for c in path.split(b"/"))


def is_phony_ref(ref: bytes) -> bool:
    """True if ``ref`` is ``@`` followed by an identifier-shaped name."""
    return _PHONY_RE.fullmatch(ref) is not None


def is_generated(path: bytes) -> bool:
    """True if the first component of ``path`` is exactly ``out``."""
    return path == b"out" or path.startswith(b"out/")
