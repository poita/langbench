import random

import pytest

from cdcl_sat import Solver, solve

from helpers import brute_force_sat, pigeonhole, random_cnf, satisfies


def test_no_clauses():
    assert solve(0, []) == []
    assert solve(3, []) is not None


def test_empty_clause():
    assert solve(2, [[1, 2], []]) is None


def test_units_and_conflict():
    assert solve(1, [[1], [-1]]) is None
    m = solve(3, [[1], [-1, 2], [-2, 3]])
    assert m == [True, True, True]


def test_tautology_and_duplicates():
    m = solve(2, [[1, -1], [2, 2, 2]])
    assert m is not None and m[1] is True
    assert solve(1, [[1, -1]]) is not None


def test_invalid_literal_rejected():
    s = Solver(2)
    with pytest.raises(ValueError):
        s.add_clause([3])
    with pytest.raises(ValueError):
        s.add_clause([0])


def test_long_clause():
    n = 1000
    clauses = [[-i] for i in range(1, n)] + [list(range(1, n + 1))]
    m = solve(n, clauses)
    assert m is not None and m[-1] is True and not any(m[:-1])


@pytest.mark.parametrize("seed", range(150))
def test_random_against_brute_force(seed):
    rng = random.Random(seed)
    n = rng.randint(1, 10)
    clauses = random_cnf(rng, n, rng.randint(0, 6 * n), width=rng.randint(1, 4))
    model = solve(n, clauses)
    if model is None:
        assert not brute_force_sat(n, clauses)
    else:
        assert satisfies(clauses, model)


def test_random_3sat_threshold():
    rng = random.Random(7)
    n = 60
    for _ in range(10):
        clauses = [
            [rng.choice([-1, 1]) * v for v in rng.sample(range(1, n + 1), 3)]
            for _ in range(int(4.26 * n))
        ]
        model = solve(n, clauses)
        if model is not None:
            assert satisfies(clauses, model)


@pytest.mark.parametrize("n", [2, 3, 5, 6])
def test_pigeonhole_unsat(n):
    nv, clauses = pigeonhole(n)
    assert solve(nv, clauses) is None


def test_exercises_reduction_and_restarts(monkeypatch):
    import cdcl_sat.solver as sv

    monkeypatch.setattr(sv, "_MAX_LEARNTS_MIN", 5)
    monkeypatch.setattr(sv, "_RESTART_BASE", 5)
    nv, clauses = pigeonhole(6)
    s = Solver(nv)
    for c in clauses:
        s.add_clause(c)
    assert s.solve() is None
    assert s.conflicts > 50


def test_solver_not_reusable_after_unsat():
    s = Solver(1)
    s.add_clause([1])
    assert not s.add_clause([-1])
    assert s.solve() is None
