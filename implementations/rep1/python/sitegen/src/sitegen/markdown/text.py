"""Small text helpers shared by the Markdown parser and renderer."""

from __future__ import annotations

import re

#: ASCII punctuation characters (the set CommonMark calls "ASCII punctuation").
ASCII_PUNCTUATION = frozenset("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

#: Whitespace as understood by cmark (``cmark_isspace``).
WHITESPACE = " \t\n\x0b\x0c\r"

_ENTITY = re.compile(
    r"&(?:#([0-9]{1,7})|#[xX]([0-9a-fA-F]{1,6})|(amp|lt|gt|quot));"
)
_NAMED = {"amp": "&", "lt": "<", "gt": ">", "quot": '"'}
_BACKSLASH_ESCAPE = re.compile(r"\\([!-/:-@\[-`{-~])")
_ESCAPE_TABLE = str.maketrans({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"})


def code_point(value: int) -> str:
    """The character for a numeric reference; invalid values give U+FFFD."""
    if value == 0 or 0xD800 <= value <= 0xDFFF or value > 0x10FFFF:
        return "\ufffd"
    return chr(value)


def _entity_replacement(match: re.Match[str]) -> str:
    dec, hexa, name = match.groups()
    if name is not None:
        return _NAMED[name]
    return code_point(int(dec) if dec is not None else int(hexa, 16))


def match_entity(text: str, pos: int) -> tuple[str, int] | None:
    """Match an entity reference whose ``&`` is at *pos*.

    Returns ``(decoded text, end position)`` or ``None``.
    """
    match = _ENTITY.match(text, pos)
    if match is None:
        return None
    return _entity_replacement(match), match.end()


def decode_entities(text: str) -> str:
    """Replace every supported entity reference in *text* by its character."""
    if "&" not in text:
        return text
    return _ENTITY.sub(_entity_replacement, text)


def unescape_backslashes(text: str) -> str:
    """Delete a backslash that precedes an ASCII punctuation character."""
    if "\\" not in text:
        return text
    return _BACKSLASH_ESCAPE.sub(r"\1", text)


def escape_html(text: str) -> str:
    """Escape ``& < > "`` for use in HTML text or attribute values."""
    return text.translate(_ESCAPE_TABLE)


_SAFE_HREF = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    "-_.~!#$%()*+,/:;=?@"
)
_HREF_PLAIN = re.compile(r"[A-Za-z0-9\-_.~!#$%()*+,/:;=?@]*")
_BLOCKED_SCHEMES = ("javascript:", "vbscript:", "file:", "data:")
_ALLOWED_DATA = ("data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp")


def href(destination: str) -> str:
    """Render a link destination as an HTML attribute value."""
    lowered = destination[:20].lower()
    if lowered.startswith(_BLOCKED_SCHEMES) and not lowered.startswith(_ALLOWED_DATA):
        return ""
    if _HREF_PLAIN.fullmatch(destination):
        return destination
    out: list[str] = []
    for ch in destination:
        if ch in _SAFE_HREF:
            out.append(ch)
        elif ch == "&":
            out.append("&amp;")
        elif ch == "'":
            out.append("&#x27;")
        else:
            out.extend(f"%{byte:02X}" for byte in ch.encode("utf-8", "surrogatepass"))
    return "".join(out)
