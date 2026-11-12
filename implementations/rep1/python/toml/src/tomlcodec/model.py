"""The in-memory document tree.

A decoded document is a tree made of three kinds of node:

* :class:`Table` -- a mapping from keys to nodes (a ``dict`` subclass);
* :class:`list` / :class:`ArrayOfTables` -- an ordered sequence of nodes;
* :class:`Scalar` -- a leaf holding a type name and its canonical *text*.

Scalars are deliberately kept as text (see :mod:`tomlcodec.tagged`): the
canonical text of a float or a date-time is the exact interchange form, and
converting to native objects and back would lose information.
"""

from __future__ import annotations

from typing import NamedTuple

#: The eight scalar type names used by the tagged-JSON interchange format.
SCALAR_TYPES = frozenset(
    {
        "string",
        "integer",
        "float",
        "bool",
        "datetime",
        "datetime-local",
        "date-local",
        "time-local",
    }
)


class Scalar(NamedTuple):
    """A leaf value: one of :data:`SCALAR_TYPES` plus its canonical text."""

    type: str
    text: str


# Definition state of a table, used while parsing to enforce TOML's rules.
IMPLICIT = 0  # created only as an intermediate segment of a header
EXPLICIT = 1  # opened by a ``[header]`` line
DOTTED = 2  # created by a dotted key (or passed through by one)
INLINE = 3  # written as an inline-table literal; closed


class Table(dict):
    """A TOML table.

    ``state`` records how the table came into existence; it is only
    meaningful while parsing, but is kept on the finished tree.
    """

    __slots__ = ("state",)

    def __init__(self, state: int = EXPLICIT) -> None:
        super().__init__()
        self.state = state


class ArrayOfTables(list):
    """An array created by ``[[header]]`` lines (as opposed to an array literal).

    The distinction matters while parsing: only arrays of tables can be
    extended by later headers.
    """

    __slots__ = ()


Node = Table | list | Scalar
