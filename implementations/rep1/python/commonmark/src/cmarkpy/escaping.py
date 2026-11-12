"""Escaping, unescaping and URL-encoding helpers."""

from __future__ import annotations

import re

#: The ASCII whitespace set of ``cmark_isspace``.
WHITESPACE = " \t\n\x0b\x0c\r"

#: ASCII punctuation characters.
PUNCTUATION = frozenset("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

_ENTITY_RE = re.compile(r"&(?:#([0-9]{1,7})|#[xX]([0-9a-fA-F]{1,6})|(amp|lt|gt|quot));")
_NAMED = {"amp": "&", "lt": "<", "gt": ">", "quot": '"'}
_BACKSLASH_RE = re.compile(r"\\([!-/:-@\[-`{-~])")
_UNSAFE_URL_RE = re.compile(r"[^A-Za-z0-9\-_.~!#$%()*+,/:;=?@]+")


def escape_html(text: str) -> str:
    """Escape ``& < > "`` for use in HTML text or attribute values."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def codepoint_to_char(cp: int) -> str:
    """Character for a numeric reference; invalid code points give U+FFFD."""
    if cp == 0 or 0xD800 <= cp <= 0xDFFF or cp > 0x10FFFF:
        return "\ufffd"
    return chr(cp)


def entity_value(match: re.Match[str]) -> str:
    """Decoded text of a match of the entity pattern."""
    dec, hexa, name = match.groups()
    if name is not None:
        return _NAMED[name]
    return codepoint_to_char(int(dec) if dec is not None else int(hexa, 16))


def match_entity(text: str, pos: int) -> re.Match[str] | None:
    """Match an entity reference starting exactly at ``text[pos]`` (the ``&``)."""
    return _ENTITY_RE.match(text, pos)


def decode_entities(text: str) -> str:
    """Replace the supported entity references in ``text`` by their characters."""
    if "&" not in text:
        return text
    return _ENTITY_RE.sub(entity_value, text)


def unescape_backslashes(text: str) -> str:
    """Remove backslashes that precede an ASCII punctuation character."""
    if "\\" not in text:
        return text
    return _BACKSLASH_RE.sub(r"\1", text)


def unescape_string(text: str) -> str:
    """Decode entities, then remove backslash escapes (in that order)."""
    return unescape_backslashes(decode_entities(text))


def _encode_run(match: re.Match[str]) -> str:
    out = []
    for ch in match.group():
        if ch == "&":
            out.append("&amp;")
        elif ch == "'":
            out.append("&#x27;")
        else:
            out.extend(f"%{b:02X}" for b in ch.encode("utf-8", "replace"))
    return "".join(out)


_BLOCKED_SCHEMES = ("javascript:", "vbscript:", "file:", "data:")
_ALLOWED_DATA = ("data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp")


def href(dest: str) -> str:
    """Render a link destination as an HTML attribute value.

    Dangerous schemes give an empty value; everything else is
    percent-encoded as cmark does and HTML-escaped where needed.
    """
    lowered = dest[:16].lower()
    if lowered.startswith(_BLOCKED_SCHEMES) and not lowered.startswith(_ALLOWED_DATA):
        return ""
    return _UNSAFE_URL_RE.sub(_encode_run, dest)
