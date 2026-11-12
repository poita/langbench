"""Structured header values: ``value; param=...`` with RFC 2231 parameters."""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .charsets import decode
from .lexical import read_quoted
from .rfc2047 import decode_unstructured
from .textutil import ascii_lower, strip_blanks


@dataclass(frozen=True, slots=True)
class StructuredValue:
    """A parsed ``Content-Type``-style header value.

    ``value`` is the first segment, blank-stripped and ASCII-lower-cased;
    ``params`` maps lower-cased parameter names to their effective values.
    """

    value: str
    params: dict[str, str] = field(default_factory=dict)


_SPLIT_POINT = re.compile(r'[;"]')


def _split_segments(s: str) -> list[str]:
    segments: list[str] = []
    start = pos = 0
    while True:
        m = _SPLIT_POINT.search(s, pos)
        if m is None:
            break
        if m.group() == ";":
            segments.append(s[start:m.start()])
            start = pos = m.end()
        else:
            pos = read_quoted(s, m.start())[1]
    segments.append(s[start:])
    return segments


def _raw_parameters(segments: list[str]) -> dict[str, str]:
    raw: dict[str, str] = {}
    for seg in segments:
        name, eq, value = seg.partition("=")
        if not eq:
            continue
        name = ascii_lower(strip_blanks(name))
        value = strip_blanks(value)
        if value.startswith('"'):
            value = read_quoted(value, 0)[0]
        raw.setdefault(name, value)
    return raw


_SEGMENT_NAME = re.compile(r"(.+)\*([0-9]+)(\*?)\Z", re.DOTALL)
_PERCENT_PIECE = re.compile(r"%[0-9A-Fa-f]{2}|[^%]+|%")


def _percent_decode(text: str) -> bytes:
    out = bytearray()
    for m in _PERCENT_PIECE.finditer(text):
        piece = m.group()
        if len(piece) == 3 and piece[0] == "%":
            out.append(int(piece[1:], 16))
        else:
            out += piece.encode("utf-8")
    return bytes(out)


def _split_extended(value: str) -> tuple[str, str]:
    """Split ``charset'language'text`` into ``(charset, text)``."""
    i = value.find("'")
    j = value.find("'", i + 1) if i >= 0 else -1
    if j < 0:
        return "us-ascii", value
    return value[:i] or "us-ascii", value[j + 1:]


@dataclass(slots=True)
class _Group:
    segments: dict[int, tuple[bool, str]] = field(default_factory=dict)
    extended: str | None = None
    plain: str | None = None


def assemble_parameters(raw: dict[str, str]) -> dict[str, str]:
    """Combine raw parameters into effective values (RFC 2231 continuations,
    percent-encoding and charsets, plus RFC 2047 words in plain values)."""
    groups: dict[str, _Group] = {}
    for name, value in raw.items():
        m = _SEGMENT_NAME.match(name)
        if m:
            g = groups.setdefault(m.group(1), _Group())
            g.segments.setdefault(int(m.group(2)), (bool(m.group(3)), value))
        elif len(name) > 1 and name.endswith("*"):
            groups.setdefault(name[:-1], _Group()).extended = value
        else:
            groups.setdefault(name, _Group()).plain = value
    result: dict[str, str] = {}
    for base, g in groups.items():
        if g.segments:
            charset = "us-ascii"
            data = bytearray()
            for n in sorted(g.segments):
                is_ext, value = g.segments[n]
                if is_ext:
                    if n == 0:
                        charset, value = _split_extended(value)
                    data += _percent_decode(value)
                else:
                    data += value.encode("utf-8")
            result[base] = decode(bytes(data), charset)
        elif g.extended is not None:
            charset, value = _split_extended(g.extended)
            result[base] = decode(_percent_decode(value), charset)
        else:
            assert g.plain is not None
            result[base] = decode_unstructured(g.plain)
    return result


def parse_structured(raw: str) -> StructuredValue:
    """Parse an unfolded raw header value into a :class:`StructuredValue`."""
    first, *rest = _split_segments(raw)
    return StructuredValue(
        ascii_lower(strip_blanks(first)),
        assemble_parameters(_raw_parameters(rest)),
    )
