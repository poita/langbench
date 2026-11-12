"""Header block parsing."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .charsets import decode_utf8
from .rfc2047 import decode_unstructured
from .textutil import ascii_lower, collapse, strip_blanks

#: A field line starts with a non-empty name of printable ASCII (no SPACE, no
#: colon) followed by a colon.
_FIELD_START = re.compile(rb"[\x21-\x39\x3b-\x7e]+:")

#: Fields whose dumped value is the blank-collapsed raw value rather than the
#: RFC 2047-decoded one.
COLLAPSED_FIELDS = frozenset(
    {
        "content-disposition",
        "content-id",
        "content-transfer-encoding",
        "content-type",
        "date",
        "in-reply-to",
        "message-id",
        "mime-version",
        "received",
        "references",
        "return-path",
    }
)


@dataclass(frozen=True, slots=True)
class Header:
    """One header field: its name and its unfolded raw value (after the colon)."""

    name: str
    value: str

    @property
    def key(self) -> str:
        """The lower-cased name with surrounding blanks removed."""
        return ascii_lower(strip_blanks(self.name))

    @property
    def display_value(self) -> str:
        """The value as shown in the dump (see ``COLLAPSED_FIELDS``)."""
        if self.key in COLLAPSED_FIELDS:
            return collapse(self.value)
        return decode_unstructured(self.value)


def parse_headers(data: bytes) -> tuple[list[Header], bytes]:
    """Split *data* (LF line endings) into header fields and the body.

    A blank line ends the block and is not part of the body; a line that is
    neither a field line nor a continuation ends it too, and starts the body.
    If the lines run out the body is empty.
    """
    n = len(data)
    pos = 0
    fields: list[list[bytes]] = []
    body = b""
    while pos < n:
        nl = data.find(b"\n", pos)
        end = n if nl < 0 else nl
        nxt = n if nl < 0 else nl + 1
        if end == pos:  # empty line
            body = data[nxt:]
            break
        if data[pos] in (0x20, 0x09) and fields:
            fields[-1].append(data[pos:end])
        elif _FIELD_START.match(data, pos):
            fields.append([data[pos:end]])
        else:
            body = data[pos:]
            break
        pos = nxt
    headers: list[Header] = []
    for lines in fields:
        text = decode_utf8(b"".join(lines))
        name, _, value = text.partition(":")
        headers.append(Header(name, value))
    return headers, body


def find_header(headers: list[Header], name: str) -> Header | None:
    """Return the first header called *name* (given lower-case), or ``None``."""
    for h in headers:
        if h.key == name:
            return h
    return None
