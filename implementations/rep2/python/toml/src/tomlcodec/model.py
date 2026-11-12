"""The document tree shared by the decoder, the encoder and the JSON layer.

A document is a :class:`Table` whose entries are :class:`Table`,
:class:`Array` or :class:`Scalar` nodes.  Scalars keep their *canonical text*
(see the specification, section 1.2) and are never converted to Python
numbers or dates, so values survive a decode/encode round trip untouched.
"""

from __future__ import annotations

from collections.abc import Iterator, Mapping, Sequence

# Scalar type names, as used in the tagged JSON format.
STRING = "string"
INTEGER = "integer"
FLOAT = "float"
BOOL = "bool"
DATETIME = "datetime"
DATETIME_LOCAL = "datetime-local"
DATE_LOCAL = "date-local"
TIME_LOCAL = "time-local"

SCALAR_TYPES = frozenset(
    {STRING, INTEGER, FLOAT, BOOL, DATETIME, DATETIME_LOCAL, DATE_LOCAL, TIME_LOCAL}
)

# How a table came into existence.  The decoder uses this to enforce the
# redefinition rules of TOML (see :mod:`tomlcodec.tables`).
IMPLICIT = 0  # intermediate segment of a ``[header]``
EXPLICIT = 1  # opened by ``[header]`` / ``[[header]]``
DOTTED = 2  # intermediate segment of a dotted key
INLINE = 3  # written as an inline-table literal


class Scalar:
    """A leaf value: a ``type`` name and its canonical ``text``."""

    __slots__ = ("type", "text")

    def __init__(self, type: str, text: str):
        self.type = type
        self.text = text

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Scalar):
            return NotImplemented
        return self.type == other.type and self.text == other.text

    def __hash__(self) -> int:
        return hash((self.type, self.text))

    def __repr__(self) -> str:
        return f"Scalar({self.type!r}, {self.text!r})"


class Array(Sequence):
    """An ordered list of nodes.

    ``is_table_array`` is true for arrays created by ``[[header]]`` lines;
    those (and only those) may be extended by later headers.
    """

    __slots__ = ("elements", "is_table_array")

    def __init__(self, elements: list | None = None, is_table_array: bool = False):
        self.elements: list = [] if elements is None else elements
        self.is_table_array = is_table_array

    def __getitem__(self, index):
        return self.elements[index]

    def __len__(self) -> int:
        return len(self.elements)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Array):
            return NotImplemented
        return self.elements == other.elements

    __hash__ = None  # type: ignore[assignment]

    def __repr__(self) -> str:
        return f"Array({self.elements!r})"


class Table(Mapping):
    """A mapping from key text to child nodes, in document order."""

    __slots__ = ("entries", "state")

    def __init__(self, entries: dict | None = None, state: int = EXPLICIT):
        self.entries: dict = {} if entries is None else entries
        self.state = state

    def __getitem__(self, key: str):
        return self.entries[key]

    def __iter__(self) -> Iterator[str]:
        return iter(self.entries)

    def __len__(self) -> int:
        return len(self.entries)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Table):
            return NotImplemented
        return self.entries == other.entries

    __hash__ = None  # type: ignore[assignment]

    def __repr__(self) -> str:
        return f"Table({self.entries!r})"


Node = Table | Array | Scalar
