"""Typing environment with O(1) lookup and undoable bindings."""

from __future__ import annotations

from .typerep import Scheme


class Env:
    """Maps each name to its innermost binding.

    ``bind`` records what it shadowed on a trail; ``rollback`` pops the trail
    back to an earlier :meth:`mark`.  Lookup and binding cost O(1) however many
    names are in scope, and nothing ever iterates over the environment.
    """

    def __init__(self, initial: dict[str, Scheme] | None = None) -> None:
        self.table: dict[str, Scheme] = dict(initial or {})
        self._trail: list[tuple[str, Scheme | None]] = []

    def lookup(self, name: str) -> Scheme | None:
        return self.table.get(name)

    def bind(self, name: str, scheme: Scheme) -> None:
        table = self.table
        self._trail.append((name, table.get(name)))
        table[name] = scheme

    def mark(self) -> int:
        return len(self._trail)

    def rollback(self, mark: int) -> None:
        trail = self._trail
        table = self.table
        while len(trail) > mark:
            name, old = trail.pop()
            if old is None:
                del table[name]
            else:
                table[name] = old

    def commit(self) -> None:
        """Make all current bindings permanent (forget the undo trail)."""
        self._trail.clear()

    def __contains__(self, name: str) -> bool:
        return name in self.table
