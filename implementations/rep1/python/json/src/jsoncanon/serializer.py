"""Canonical serializer.

Output is produced by one pass over the tree with an explicit stack, appending
fragments to a single list that is joined once at the end; nothing is built
per subtree and copied into its parent.
"""

from __future__ import annotations

import re
from typing import Any

from .values import Number, Object

_NEEDS_ESCAPE = re.compile(r'[\x00-\x1f"\\]')

_ESCAPES = {chr(i): f"\\u{i:04x}" for i in range(0x20)}
_ESCAPES.update(
    {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
)


def _escape_match(m: re.Match[str]) -> str:
    return _ESCAPES[m.group()]


def quote(s: str) -> str:
    """Return ``s`` as a canonical JSON string literal (quotes included)."""
    if _NEEDS_ESCAPE.search(s) is None:
        return f'"{s}"'
    return f'"{_NEEDS_ESCAPE.sub(_escape_match, s)}"'


def _utf16_key(s: str) -> bytes:
    # Big-endian UTF-16 bytes compare exactly like sequences of unsigned
    # 16-bit code units, with a proper prefix sorting first.
    return s.encode("utf-16-be", "surrogatepass")


def canonical_members(members: list[tuple[str, Any]]) -> list[tuple[str, Any]]:
    """Resolve duplicate keys (last wins) and sort by UTF-16 code units."""
    merged = dict(members)  # equal keys: first position, last value
    if len(merged) == 1:
        return list(merged.items())
    return [(k, merged[k]) for k in sorted(merged, key=_utf16_key)]


def dump_text(value: Any) -> str:
    """Serialize a parsed value to its canonical text (no trailing newline)."""
    out: list[str] = []
    append = out.append
    # Each frame: [iterator, closing text, is_object, started]
    stack: list[list] = []
    cur = value
    while True:
        t = type(cur)
        if t is str:
            append(quote(cur))
        elif t is Number:
            append(cur)
        elif cur is None:
            append("null")
        elif cur is True:
            append("true")
        elif cur is False:
            append("false")
        elif t is list:
            if cur:
                append("[")
                stack.append([iter(cur), "]", False, False])
            else:
                append("[]")
        elif t is Object:
            if cur.members:
                append("{")
                stack.append([iter(canonical_members(cur.members)), "}", True, False])
            else:
                append("{}")
        else:
            raise TypeError(f"cannot serialize {t.__name__}")

        # advance to the next value to emit, closing finished containers
        while True:
            if not stack:
                return "".join(out)
            frame = stack[-1]
            nxt = next(frame[0], frame)  # ``frame`` itself is the end marker
            if nxt is frame:
                append(frame[1])
                stack.pop()
                continue
            if frame[3]:
                append(",")
            else:
                frame[3] = True
            if frame[2]:
                append(quote(nxt[0]))
                append(":")
                cur = nxt[1]
            else:
                cur = nxt
            break


def dump(value: Any) -> bytes:
    """Serialize a parsed value to canonical UTF-8 bytes (no newline)."""
    return dump_text(value).encode("utf-8")
