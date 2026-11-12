"""The high-level parsed-message object."""

from __future__ import annotations

from dataclasses import dataclass

from .addresses import Address, parse_address_list
from .dates import ParsedDate, parse_date
from .parts import Part, build_parts
from .selection import select
from .textutil import normalize_newlines

#: Address headers, in the order they are reported.
ADDRESS_FIELDS = ("from", "sender", "reply-to", "to", "cc", "bcc")


@dataclass(slots=True, eq=False)
class Message:
    """A parsed email message.

    ``size`` is the length of the original bytes; ``parts`` lists every part
    in pre-order (``parts[0]`` is the message itself).
    """

    size: int
    parts: list[Part]
    text_part: Part | None
    html_part: Part | None
    attachments: list[Part]

    @property
    def root(self) -> Part:
        return self.parts[0]

    @property
    def headers(self):
        """The top-level header fields, in order."""
        return self.root.headers

    def addresses(self, field: str) -> list[Address]:
        """All addresses of every header called *field* (lower-case), in order."""
        result: list[Address] = []
        for h in self.headers:
            if h.key == field:
                result.extend(parse_address_list(h.value))
        return result

    @property
    def date_raw(self) -> str | None:
        """The raw value of the ``Date`` header, or ``None`` if there is none."""
        h = self.root.header("date")
        return None if h is None else h.value

    @property
    def date(self) -> ParsedDate | None:
        """The parsed ``Date`` header, or ``None`` if absent or invalid."""
        raw = self.date_raw
        return None if raw is None else parse_date(raw)


def parse_message(data: bytes) -> Message:
    """Parse the bytes of one message (CRLF or LF line endings)."""
    parts = build_parts(normalize_newlines(data))
    sel = select(parts)
    return Message(len(data), parts, sel.text, sel.html, sel.attachments)
