"""Thistlethwaite's four-phase solver with exact per-phase distance tables."""

from __future__ import annotations

import functools
from collections.abc import Iterable

from . import coords
from .cube import Cube
from .model import MOVE_NAMES
from .notation import parse_moves
from .tables import UNREACHED, build_distance_table


class _Phase:
    """A coordinate space plus its (lazily built) distance table."""

    def __init__(self, builder):
        self._builder = builder
        self.space: coords.CoordinateSpace | None = None
        self.dist: bytearray | None = None

    def ensure(self) -> None:
        if self.dist is None:
            self.space = self._builder()
            self.dist = build_distance_table(self.space)

    def descend(self, cube: Cube, out: list[str]) -> None:
        """Greedily walk ``cube`` to the phase goal, appending moves to ``out``."""
        space = self.space
        s = space.encode(cube)
        nb = space.nb
        dist = self.dist
        d = dist[s]
        if d == UNREACHED:
            raise ValueError("cube is not in a state solvable by this phase "
                             "(is it a valid cube?)")
        triples = list(zip(space.moves, space.a_tables, space.b_tables))
        while d:
            a = s // nb
            b = s - a * nb
            for mi, ta, tb in triples:
                n = ta[a] + tb[b]
                if dist[n] == d - 1:
                    break
            else:  # pragma: no cover - impossible for a correct BFS table
                raise AssertionError("no improving move")
            cube.apply(mi)
            out.append(MOVE_NAMES[mi])
            s, d = n, d - 1


class Solver:
    """Solves cubes with Thistlethwaite's algorithm.

    The four distance tables are built lazily, once per ``Solver``, the first
    time a cube needs the corresponding phase, and are then shared by all
    :meth:`solve` calls.  A full build takes a few seconds.  Solutions use at
    most 7 + 10 + 13 + 15 = 45 moves.
    """

    def __init__(self):
        self._phases = [_Phase(b) for b in coords.PHASES]

    def solve(self, cube: Cube) -> list[str]:
        """Moves that bring ``cube`` to the solved state (``cube`` is not modified).

        Raises:
            ValueError: if ``cube`` is not a valid (reachable) cube state.
        """
        work = cube.copy()
        out: list[str] = []
        for phase in self._phases:
            phase.ensure()
            phase.descend(work, out)
        if not work.is_solved():
            raise ValueError("cube is not a valid, reachable cube state")
        return out

    def solve_scramble(self, scramble: str | Iterable[str]) -> list[str]:
        """Solve the cube obtained by applying ``scramble`` to a solved cube."""
        if isinstance(scramble, str):
            scramble = parse_moves(scramble)
        return self.solve(Cube.from_moves(scramble))

    def build_all(self) -> None:
        """Eagerly build every table (otherwise they are built on demand)."""
        for phase in self._phases:
            phase.ensure()


@functools.cache
def default_solver() -> Solver:
    """A process-wide shared :class:`Solver`, so tables are built only once."""
    return Solver()


def solve(scramble: str | Iterable[str]) -> list[str]:
    """Solve the cube scrambled by ``scramble`` (string or token list)."""
    return default_solver().solve_scramble(scramble)
