"""Sizes and eccentricities of the phase tables (Thistlethwaite's bounds)."""

import pytest

from rubiks import coords
from rubiks.tables import UNREACHED

EXPECTED = [  # (space size, reachable states, max distance)
    (2048, 2048, 7),
    (1082565, 1082565, 10),
    (29400, 29400, 13),
    (1327104, 663552, 15),
]


@pytest.mark.parametrize("i", range(4))
def test_phase_table(solver, i):
    phase = solver._phases[i]
    size, reachable, depth = EXPECTED[i]
    assert phase.space.size == size
    assert len(phase.dist) == size
    visited = [d for d in phase.dist if d != UNREACHED]
    assert len(visited) == reachable
    assert max(visited) == depth
    assert phase.dist[phase.space.goal] == 0


def test_move_sets():
    assert [len(m) for m in (coords.PHASE1_MOVES, coords.PHASE2_MOVES,
                             coords.PHASE3_MOVES, coords.PHASE4_MOVES)] == [18, 14, 10, 6]
