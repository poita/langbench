"""The spreadsheet model with incremental recalculation.

Each cell stores its parsed formula and its current value.  The sheet keeps
forward edges (a cell's dependencies) and reverse edges (a cell's dependents).
After every edit the *affected set* -- the edited cell plus everything that
transitively reads it -- is found by walking reverse edges; Tarjan's
strongly-connected-components algorithm over the subgraph induced by that set
yields components dependencies-first.  Cyclic components get ``#CYCLE!``; every
other cell is evaluated as soon as its component is emitted.
"""

from __future__ import annotations

import sys
from typing import Iterator

from .evaluator import evaluate
from .parser import ParsedFormula, parse_formula
from .refs import cell_name, parse_ref
from .values import CYCLE, Value, display

__all__ = ["Sheet"]

_NO_DEPS: frozenset[int] = frozenset()
_RECURSION_LIMIT = 200_000


class _Cell:
    __slots__ = ("formula", "deps", "value")

    def __init__(self, value: Value, formula: ParsedFormula | None = None) -> None:
        self.formula = formula
        self.deps = _NO_DEPS if formula is None else formula.deps
        self.value = value


def _parse_literal(content: str) -> float | str:
    """Parse a string or number literal (non-formula content)."""
    if len(content) >= 2 and content[0] == '"' and content[-1] == '"':
        return content[1:-1]
    return float(content) + 0.0  # "-0" -> 0.0 is fine; display shows "0"


class Sheet:
    """An in-memory spreadsheet.

    Cells are addressed by name (``"A1"`` .. ``"ZZ9999"``).  Contents are the
    same text accepted by the ``set`` command: a number (``42``), a string
    literal (``"text"``) or a formula (``=A1+B1``).
    """

    def __init__(self) -> None:
        # Formula trees can be thousands of levels deep (e.g. long `1+1+...`
        # chains), and the evaluator walks them recursively.
        if sys.getrecursionlimit() < _RECURSION_LIMIT:
            sys.setrecursionlimit(_RECURSION_LIMIT)
        self._cells: dict[int, _Cell] = {}
        self._dependents: dict[int, set[int]] = {}

    # -- public API ------------------------------------------------------
    def set(self, name: str, content: str) -> None:
        """Replace the content of cell *name* and recalculate."""
        key = self._key(name)
        if content.startswith("="):
            formula = parse_formula(content[1:])
            cell = _Cell(None, formula)
        else:
            cell = _Cell(_parse_literal(content))
        self._detach(key)
        self._cells[key] = cell
        for dep in cell.deps:
            self._dependents.setdefault(dep, set()).add(key)
        self._recalculate(key)

    def clear(self, name: str) -> None:
        """Make cell *name* empty and recalculate its dependents."""
        key = self._key(name)
        self._detach(key)
        self._cells.pop(key, None)
        self._recalculate(key)

    def value(self, name: str) -> Value:
        """Return the value of cell *name*: float, str, CellError or None."""
        cell = self._cells.get(self._key(name))
        return None if cell is None else cell.value

    def get(self, name: str) -> str:
        """Return the displayed value of cell *name* ("" if empty)."""
        return display(self.value(name))

    def dump(self) -> list[tuple[str, str]]:
        """Return ``(name, displayed value)`` for each non-empty cell,
        in row-major order."""
        return [
            (cell_name(key), display(self._cells[key].value))
            for key in sorted(self._cells)
        ]

    def __len__(self) -> int:
        return len(self._cells)

    # -- internals -------------------------------------------------------
    @staticmethod
    def _key(name: str) -> int:
        key = parse_ref(name)
        if key is None:
            raise ValueError(f"invalid cell name: {name!r}")
        return key

    def _detach(self, key: int) -> None:
        """Remove the reverse edges contributed by the cell at *key*."""
        old = self._cells.get(key)
        if old is None:
            return
        dependents = self._dependents
        for dep in old.deps:
            readers = dependents.get(dep)
            if readers is not None:
                readers.discard(key)
                if not readers:
                    del dependents[dep]

    def _affected(self, key: int) -> set[int]:
        """The edited cell plus every cell that transitively reads it."""
        dependents = self._dependents
        seen = {key}
        stack = [key]
        while stack:
            for reader in dependents.get(stack.pop(), ()):
                if reader not in seen:
                    seen.add(reader)
                    stack.append(reader)
        return seen

    def _recalculate(self, key: int) -> None:
        for component in self._components(self._affected(key)):
            first = self._cells.get(component[0])
            if first is None:  # the edited cell was just cleared
                continue
            if len(component) > 1 or component[0] in first.deps:
                for member in component:
                    self._cells[member].value = CYCLE
            elif first.formula is not None:
                v = evaluate(first.formula.root, self._cells)
                first.value = 0.0 if v is None else v

    def _components(self, affected: set[int]) -> Iterator[list[int]]:
        """Tarjan's algorithm (iterative) over the subgraph induced by
        *affected*, yielding components dependencies-first."""
        cells = self._cells
        index: dict[int, int] = {}
        low: dict[int, int] = {}
        on_stack: set[int] = set()
        stack: list[int] = []
        counter = 0
        for root in affected:
            if root in index:
                continue
            index[root] = low[root] = counter
            counter += 1
            stack.append(root)
            on_stack.add(root)
            root_cell = cells.get(root)
            work = [(root, iter(root_cell.deps if root_cell else ()))]
            while work:
                v, it = work[-1]
                for w in it:
                    if w not in affected:
                        continue
                    if w not in index:
                        index[w] = low[w] = counter
                        counter += 1
                        stack.append(w)
                        on_stack.add(w)
                        w_cell = cells.get(w)  # None: the just-cleared cell
                        work.append((w, iter(w_cell.deps if w_cell else ())))
                        break
                    if w in on_stack and index[w] < low[v]:
                        low[v] = index[w]
                else:
                    work.pop()
                    if work:
                        parent = work[-1][0]
                        if low[v] < low[parent]:
                            low[parent] = low[v]
                    if low[v] == index[v]:
                        component = []
                        while True:
                            w = stack.pop()
                            on_stack.discard(w)
                            component.append(w)
                            if w == v:
                                break
                        yield component
