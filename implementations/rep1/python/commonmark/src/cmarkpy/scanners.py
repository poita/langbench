"""Low-level scanners used by the inline parser.

Every scanner works from a given position and its cost is proportional to the
characters it examines, never to the rest of the content.
"""

from __future__ import annotations

import re

from .escaping import PUNCTUATION

_WS_RE = re.compile(r"[ \t\n\x0b\x0c\r]*")
_BARE_CHUNK_RE = re.compile(r"[^\\()\x20\t\n\x0b\x0c\r]*")
_ANGLE_DEST_RE = re.compile(r"<((?:[^<>\\\n]|\\.)*)>", re.DOTALL)
_PAREN_RE = re.compile(r"[()]")

#: URI autolink (group 1) or email autolink (group 2), after the ``<``.
AUTOLINK_RE = re.compile(
    r"<(?:([A-Za-z][A-Za-z0-9.+-]{1,31}:[^\x00-\x20<>]*)"
    r"|([a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"
    r"(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*))>"
)

_MAX_PAREN_DEPTH = 32


def skip_whitespace(text: str, pos: int) -> int:
    """Return the index of the first non-whitespace character at or after ``pos``."""
    return _WS_RE.match(text, pos).end()


def scan_title(text: str, pos: int) -> int | None:
    """Scan a link title starting at the opening delimiter ``text[pos]``.

    Returns the index just after the closing delimiter, or ``None``.  The
    match is the longest one in which the closing delimiter (and, for the
    parenthesised form, also ``(``) occurs inside the title only when
    preceded by a backslash.
    """
    opener = text[pos]
    last = -1
    j = pos + 1
    if opener != "(":
        find = text.find
        while True:
            q = find(opener, j)
            if q < 0:
                break
            if text[q - 1] != "\\":
                return q + 1
            last = q
            j = q + 1
    else:
        search = _PAREN_RE.search
        while True:
            m = search(text, j)
            if m is None:
                break
            q = m.start()
            escaped = text[q - 1] == "\\"
            if text[q] == ")":
                if not escaped:
                    return q + 1
                last = q
            elif not escaped:
                break
            j = q + 1
    return last + 1 if last >= 0 else None


def scan_inline_link_tail(text: str, pos: int) -> tuple[str, str | None, int] | None:
    """Scan ``(destination "title")`` starting at ``text[pos]``, right after a ``]``.

    Returns ``(raw_destination, raw_title, end)`` where ``end`` is the index
    after the closing parenthesis, or ``None`` if there is no inline link.
    Destination and title are returned raw (still to be unescaped).
    """
    n = len(text)
    if pos >= n or text[pos] != "(":
        return None
    i = skip_whitespace(text, pos + 1)
    if i >= n:
        return None
    if text[i] == "<":
        m = _ANGLE_DEST_RE.match(text, i)
        if m is None:
            return None
        dest = m.group(1)
        i = m.end()
    else:
        depth = 0
        j = i
        while j < n:
            j = _BARE_CHUNK_RE.match(text, j).end()
            if j >= n:
                break
            c = text[j]
            if c == "\\":
                j += 2 if j + 1 < n and text[j + 1] in PUNCTUATION else 1
            elif c == "(":
                depth += 1
                if depth > _MAX_PAREN_DEPTH:
                    return None
                j += 1
            elif c == ")":
                if depth == 0:
                    break
                depth -= 1
                j += 1
            else:
                break
        if j >= n or depth != 0:
            return None
        dest = text[i:j]
        i = j
    if i >= n:
        return None
    k = skip_whitespace(text, i)
    title = None
    if k > i and k < n and text[k] in "\"'(":
        end = scan_title(text, k)
        if end is not None:
            title = text[k + 1 : end - 1]
            k = skip_whitespace(text, end)
    if k >= n or text[k] != ")":
        return None
    return dest, title, k + 1
