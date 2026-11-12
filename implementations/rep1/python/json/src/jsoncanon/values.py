"""Data representation of parsed documents.

======================  ===============================================
JSON                    Python
======================  ===============================================
``null``                ``None``
``true`` / ``false``    ``True`` / ``False``
string                  ``str`` (decoded, always valid Unicode scalars)
number                  :class:`Number` (``str`` subclass, canonical text)
array                   ``list``
object                  :class:`Object` (members in input order)
======================  ===============================================
"""

from __future__ import annotations

from typing import Any


class Number(str):
    """A JSON number, held as its canonical text.

    Numbers are never converted to floating point, so integers of any size
    and any number of fraction digits survive untouched.  The text is the
    lexeme with its exponent normalised (see :func:`jsoncanon.parse`).
    """

    __slots__ = ()


class Object:
    """A JSON object: all ``(key, value)`` members in input order.

    Duplicate keys are kept here; they are resolved (last one wins) and the
    members sorted only when the object is serialised.
    """

    __slots__ = ("members",)

    def __init__(self, members: list[tuple[str, Any]] | None = None) -> None:
        self.members: list[tuple[str, Any]] = [] if members is None else members

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Object) and self.members == other.members

    __hash__ = None  # type: ignore[assignment]

    def __repr__(self) -> str:
        return f"Object({self.members!r})"
