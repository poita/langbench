"""Choosing the text and HTML bodies and listing the attachments."""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass

from .parts import Kind, Part


@dataclass(frozen=True, slots=True)
class Selection:
    """The outcome of body selection for one message."""

    text: Part | None
    html: Part | None
    attachments: list[Part]


def _walk(part: Part) -> Iterator[Part]:
    """Pre-order walk that does not enter ``message/rfc822`` children."""
    yield part
    if part.kind is not Kind.MESSAGE:
        for child in part.children:
            yield from _walk(child)


def _is_body_candidate(part: Part) -> bool:
    return part.is_leaf and part.disposition != "attachment"


def select(parts: list[Part]) -> Selection:
    """Select bodies and attachments from a pre-order part list."""
    text = html = None
    for part in _walk(parts[0]):
        if not _is_body_candidate(part):
            continue
        if text is None and part.content_type == "text/plain":
            text = part
        elif html is None and part.content_type == "text/html":
            html = part
    attachments = [p for p in parts if p.is_leaf and p is not text and p is not html]
    return Selection(text, html, attachments)
