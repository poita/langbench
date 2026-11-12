"""Edit scripts: the :class:`Edit` record plus formatting and parsing."""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from typing import NamedTuple

KEEP = " "
DELETE = "-"
INSERT = "+"
TAGS = (KEEP, DELETE, INSERT)


class Edit(NamedTuple):
    """One edit-script operation: a tag (``' '``, ``'-'`` or ``'+'``) and a line."""

    tag: str
    text: str

    def __str__(self) -> str:
        return self.tag + self.text


def cost(script: Iterable[Edit]) -> int:
    """Number of deletions plus insertions in *script*."""
    return sum(1 for e in script if e.tag != KEEP)


def format_script(script: Sequence[Edit]) -> str:
    """Render *script* as a count line followed by one line per edit."""
    parts = [str(len(script)), "\n"]
    for e in script:
        parts.append(e.tag)
        parts.append(e.text)
        parts.append("\n")
    return "".join(parts)


def parse_script_lines(lines: Iterable[str]) -> list[Edit]:
    """Turn raw script lines (tag char + content) into :class:`Edit` records.

    Raises :class:`ValueError` for an empty line or an unknown tag.
    """
    out: list[Edit] = []
    for n, line in enumerate(lines, 1):
        if not line or line[0] not in TAGS:
            raise ValueError(f"script line {n}: missing or invalid tag")
        out.append(Edit(line[0], line[1:]))
    return out


def old_lines(script: Iterable[Edit]) -> list[str]:
    """The lines of file A that *script* consumes (keeps and deletions)."""
    return [e.text for e in script if e.tag != INSERT]


def new_lines(script: Iterable[Edit]) -> list[str]:
    """The lines of file B that *script* produces (keeps and insertions)."""
    return [e.text for e in script if e.tag != DELETE]
