"""Lexical helpers shared by header parsers: quoted strings and comments."""

from __future__ import annotations

import re

_QUOTE_STOP = re.compile(r'[\\"]')


def read_quoted(s: str, i: int) -> tuple[str, int]:
    """Read the quoted string whose opening ``"`` is at ``s[i]``.

    Returns ``(contents, end)`` where *contents* has backslash escapes
    resolved and *end* is the index just past the closing quote.  An unclosed
    string extends to the end of *s*; a trailing backslash stands for itself.
    """
    n = len(s)
    j = i + 1
    parts: list[str] = []
    while j < n:
        m = _QUOTE_STOP.search(s, j)
        if m is None:
            parts.append(s[j:])
            return "".join(parts), n
        k = m.start()
        parts.append(s[j:k])
        if s[k] == '"':
            return "".join(parts), k + 1
        if k + 1 < n:
            parts.append(s[k + 1])
            j = k + 2
        else:
            parts.append("\\")
            j = k + 1
    return "".join(parts), n


def skip_comment(s: str, i: int) -> int:
    """Return the index just past the comment whose ``(`` is at ``s[i]``.

    Comments nest; a backslash quotes the next character.  An unterminated
    comment runs to the end of *s*.
    """
    n = len(s)
    depth = 0
    j = i
    while j < n:
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n
