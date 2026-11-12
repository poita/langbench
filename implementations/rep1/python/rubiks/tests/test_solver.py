import random

import pytest

from rubiks import Cube, Solver, invert_moves, parse_moves, solve

from facelets import SOLVED, apply

SCRAMBLES = [
    "",
    "R",
    "R'",
    "U2",
    "F R U'",
    "R U R' U' " * 6,
    "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2",   # superflip
    "U2 D2 R2 L2 F2 B2",                                      # checkerboard
    "R2 L2 U2 D2 F2 B2",
    "F L F U' R U F2 L2 U' L' B D' B' L2 U",                  # T-perm-ish
]


def check(scramble, solution):
    assert len(solution) <= 45
    assert apply(SOLVED, parse_moves(scramble) + solution) == SOLVED


@pytest.mark.parametrize("scramble", SCRAMBLES)
def test_known_scrambles(solver, scramble):
    check(scramble, solver.solve_scramble(scramble))


def test_random_scrambles(solver):
    rng = random.Random(1234)
    moves = [f + s for f in "UDLRFB" for s in ("", "'", "2")]
    for _ in range(40):
        scramble = " ".join(rng.choice(moves) for _ in range(rng.choice([5, 20, 25, 60])))
        check(scramble, solver.solve_scramble(scramble))


def test_long_scramble(solver):
    rng = random.Random(7)
    moves = [f + s for f in "UDLRFB" for s in ("", "'", "2")]
    scramble = " ".join(rng.choice(moves) for _ in range(1000))
    check(scramble, solver.solve_scramble(scramble))


def test_solve_does_not_mutate_input(solver):
    cube = Cube.from_moves("R U F")
    before = cube.copy()
    sol = solver.solve(cube)
    assert cube == before
    cube.apply_moves(sol)
    assert cube.is_solved()


def test_inverse_scramble_solution(solver):
    scramble = parse_moves("R U2 F' D L2 B")
    sol = solver.solve_scramble(scramble)
    assert Cube.from_moves(scramble + sol).is_solved()
    assert Cube.from_moves(scramble + invert_moves(scramble)).is_solved()


def test_invalid_cube_rejected(solver):
    cube = Cube()
    cube.co[0] = 1  # a single twisted corner is unreachable
    with pytest.raises(ValueError):
        solver.solve(cube)


def test_module_level_solve():
    sol = solve("R U")
    assert Cube.from_moves(["R", "U"] + sol).is_solved()
