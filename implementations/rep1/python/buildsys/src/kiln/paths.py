"""Workspace path rules (SPEC "Workspace paths")."""

from __future__ import annotations

import re

OUT_DIR = b"out"
STATE_FILE = b".kiln-state"

_PATH_RE = re.compile(rb"[A-Za-z0-9_.+\-]{1,255}(?:/[A-Za-z0-9_.+\-]{1,255})*")
_IDENT_RE = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*")


def is_workspace_path(path: bytes) -> bool:
    """True when *path* is a valid workspace path."""
    if len(path) > 1024 or _PATH_RE.fullmatch(path) is None:
        return False
    for comp in path.split(b"/"):
        if comp == b"." or comp == b"..":
            return False
    return True


def is_identifier(name: bytes) -> bool:
    """True for ``[A-Za-z_][A-Za-z0-9_]*``."""
    return _IDENT_RE.fullmatch(name) is not None


def is_phony_ref(ref: bytes) -> bool:
    """True for ``@`` followed by an identifier-shaped name."""
    return ref[:1] == b"@" and is_identifier(ref[1:])


def is_reference(ref: bytes) -> bool:
    """True when *ref* is a phony reference or a workspace path."""
    return is_phony_ref(ref) or is_workspace_path(ref)


def is_generated(path: bytes) -> bool:
    """True when the first component of *path* is exactly ``out``."""
    return path == OUT_DIR or path.startswith(b"out/")
