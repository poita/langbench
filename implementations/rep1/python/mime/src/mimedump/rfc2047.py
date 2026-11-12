"""RFC 2047 encoded words and the two free-text decoders built on them."""

from __future__ import annotations

import re

from .charsets import decode
from .lexical import read_quoted, skip_comment
from .textutil import ascii_lower, strip_blanks
from .transfer import decode_base64

_Q_PIECE = re.compile(r"=[0-9A-Fa-f]{2}|_|[^=_]+|=")


def _decode_q(text: str) -> bytes:
    out = bytearray()
    for m in _Q_PIECE.finditer(text):
        piece = m.group()
        if piece == "_":
            out.append(0x20)
        elif len(piece) == 3 and piece[0] == "=":
            out.append(int(piece[1:], 16))
        else:
            out += piece.encode("utf-8")
    return bytes(out)


def match_encoded_word(v: str, i: int) -> tuple[str, int] | None:
    """Try to read an encoded word starting at ``v[i]``.

    Returns ``(decoded_text, end)`` or ``None`` when no encoded word starts
    there.  The word is ``=?charset?Q|B?text?=`` where the charset and text
    contain no blanks.
    """
    if not v.startswith("=?", i):
        return None
    j = v.find("?", i + 2)
    if j < 0:
        return None
    charset_field = v[i + 2:j]
    if not charset_field or " " in charset_field or "\t" in charset_field:
        return None
    enc = v[j + 1:j + 2]
    if enc not in ("Q", "q", "B", "b") or v[j + 2:j + 3] != "?":
        return None
    m = v.find("?", j + 3)
    if m < 0:
        return None
    text = v[j + 3:m]
    if " " in text or "\t" in text:
        return None
    if v[m + 1:m + 2] != "=":
        return None
    charset = ascii_lower(strip_blanks(charset_field.split("*", 1)[0])) or "us-ascii"
    raw = _decode_q(text) if enc in ("Q", "q") else decode_base64(text.encode("utf-8"))
    return decode(raw, charset), m + 2


_SPACE, _LITERAL, _ENCODED = 0, 1, 2
_RUN = re.compile(r"[ \t]+|[^ \t]+")
_UNSTRUCTURED_STARTS = re.compile(r"=\?")
_DISPLAY_STARTS = re.compile(r'=\?|\(|"')


def _add_plain(items: list[tuple[int, str]], s: str) -> None:
    for m in _RUN.finditer(s):
        run = m.group()
        items.append((_SPACE if run[0] in " \t" else _LITERAL, run))


def _scan(v: str, starts: re.Pattern[str]) -> str:
    items: list[tuple[int, str]] = []
    pos = search = 0
    while True:
        m = starts.search(v, search)
        if m is None:
            _add_plain(items, v[pos:])
            break
        i = m.start()
        c = v[i]
        if c == "=":
            word = match_encoded_word(v, i)
            if word is None:
                search = i + 1
                continue
            _add_plain(items, v[pos:i])
            items.append((_ENCODED, word[0]))
            pos = search = word[1]
        elif c == "(":
            _add_plain(items, v[pos:i])
            items.append((_SPACE, " "))
            pos = search = skip_comment(v, i)
        else:
            _add_plain(items, v[pos:i])
            text, end = read_quoted(v, i)
            items.append((_LITERAL, text))
            pos = search = end
    out: list[str] = []
    last = len(items) - 1
    for k, (kind, text) in enumerate(items):
        if (
            kind == _SPACE
            and 0 < k < last
            and items[k - 1][0] == _ENCODED
            and items[k + 1][0] == _ENCODED
        ):
            continue
        out.append(text)
    return strip_blanks("".join(out))


def decode_unstructured(v: str) -> str:
    """Decode the encoded words of an unstructured header value.

    Blanks between two adjacent encoded words are dropped; the result is
    stripped of leading and trailing blanks.
    """
    if "=?" not in v:
        return strip_blanks(v)
    return _scan(v, _UNSTRUCTURED_STARTS)


def decode_display(s: str) -> str:
    """Decode an address phrase.

    Like :func:`decode_unstructured`, but each comment becomes one space and
    each quoted string becomes its unescaped contents (encoded words inside
    it are left alone).
    """
    return _scan(s, _DISPLAY_STARTS)
