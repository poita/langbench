"""Table-resolution rules of TOML 1.0.0 (specification section 1.3, "Tables").

These functions walk the tree for ``[header]``, ``[[header]]`` and dotted-key
statements and enforce which tables may be re-opened, extended or defined.
They raise :class:`~tomlcodec.errors.TomlDecodeError` (without a position;
the parser attaches one) on any violation.
"""

from __future__ import annotations

from collections.abc import Sequence

from .errors import TomlDecodeError
from .model import DOTTED, EXPLICIT, IMPLICIT, INLINE, Array, Node, Table


def _step(table: Table, key: str) -> Table:
    """Resolve an intermediate header segment, creating implicit tables."""
    child = table.entries.get(key)
    if child is None:
        child = Table(state=IMPLICIT)
        table.entries[key] = child
        return child
    if isinstance(child, Table):
        if child.state == INLINE:
            raise TomlDecodeError(f"cannot extend inline table {key!r}")
        return child
    if isinstance(child, Array) and child.is_table_array:
        return child.elements[-1]
    raise TomlDecodeError(f"key {key!r} is not a table")


def open_table(root: Table, keys: Sequence[str]) -> Table:
    """Handle a ``[a.b.c]`` header and return the table it opens."""
    table = root
    for key in keys[:-1]:
        table = _step(table, key)
    last = keys[-1]
    existing = table.entries.get(last)
    if existing is None:
        new = Table(state=EXPLICIT)
        table.entries[last] = new
        return new
    if isinstance(existing, Table) and existing.state == IMPLICIT:
        existing.state = EXPLICIT
        return existing
    raise TomlDecodeError(f"table {last!r} is already defined")


def open_table_array(root: Table, keys: Sequence[str]) -> Table:
    """Handle a ``[[a.b]]`` header: append a new element and return it."""
    table = root
    for key in keys[:-1]:
        table = _step(table, key)
    last = keys[-1]
    existing = table.entries.get(last)
    new = Table(state=EXPLICIT)
    if existing is None:
        table.entries[last] = Array([new], is_table_array=True)
        return new
    if isinstance(existing, Array) and existing.is_table_array:
        existing.elements.append(new)
        return new
    raise TomlDecodeError(f"{last!r} is not an array of tables")


def assign(table: Table, keys: Sequence[str], node: Node) -> None:
    """Store ``node`` under the (possibly dotted) ``keys`` inside ``table``."""
    for key in keys[:-1]:
        child = table.entries.get(key)
        if child is None:
            child = Table(state=DOTTED)
            table.entries[key] = child
        elif not isinstance(child, Table) or child.state in (EXPLICIT, INLINE):
            raise TomlDecodeError(f"cannot extend {key!r} with a dotted key")
        table = child
    last = keys[-1]
    if last in table.entries:
        raise TomlDecodeError(f"duplicate key {last!r}")
    table.entries[last] = node
