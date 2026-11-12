import pytest

from cdcl_sat import Solver, solve
from conftest import (
    brute_force_sat, make_rng, pigeonhole, random_cnf, satisfies,
)


def test_no_clauses():
    assert solve([], 0) == []
    assert solve([], 3) == [-1, -2, -3]


def test_empty_clause_is_unsat():
    assert solve([[1], []], 1) is None
    assert solve([[]], 0) is None


def test_tautology_and_duplicates():
    model = solve([[1, -1], [2, 2, 2]], 2)
    assert model[1] == 2
    assert solve([[1, -1], [1], [-1]], 1) is None


def test_unit_propagation_chain():
    clauses = [[1], [-1, 2], [-2, 3], [-3, 4]]
    assert solve(clauses, 4) == [1, 2, 3, 4]
    assert solve(clauses + [[-4]], 4) is None


def test_unused_variables_get_a_value():
    model = solve([[1]], 5)
    assert len(model) == 5 and model[0] == 1
    assert [abs(x) for x in model] == [1, 2, 3, 4, 5]


def test_long_clause():
    clause = list(range(1, 1001))
    model = solve([clause], 1000)
    assert satisfies(model, [clause])


def test_pigeonhole_unsat():
    for holes in (2, 3, 4, 5):
        n, clauses = pigeonhole(holes)
        assert solve(clauses, n) is None


def test_pigeonhole_with_spare_hole_is_sat():
    n, clauses = pigeonhole(4)
    # drop the last pigeon's "some hole" clause: now satisfiable
    clauses = [c for c in clauses if c != [4 * 4 + h + 1 for h in range(4)]]
    model = solve(clauses, n)
    assert model is not None and satisfies(model, clauses)


@pytest.mark.parametrize("seed", range(150))
def test_random_against_brute_force(seed):
    rng = make_rng(seed)
    n = rng.randint(1, 10)
    m = rng.randint(0, int(n * 5))
    clauses = random_cnf(rng, n, m, width=rng.choice([1, 2, 3]))
    model = solve(clauses, n)
    expected = brute_force_sat(n, clauses)
    assert (model is not None) == expected
    if model is not None:
        assert len(model) == n
        assert satisfies(model, clauses)


def test_harder_random_forces_learning_and_reduction():
    rng = make_rng(7)
    n = 120
    clauses = random_cnf(rng, n, int(4.26 * n))
    s = Solver(n)
    for c in clauses:
        s.add_clause(c)
    result = s.solve()
    assert s.conflicts > 0
    if result:
        assert satisfies(s.model(), clauses)


def test_reduce_db_path(monkeypatch):
    import cdcl_sat.solver as mod

    monkeypatch.setattr(mod, "_MAX_LEARNTS_FLOOR", 5)
    monkeypatch.setattr(mod, "_RESTART_UNIT", 5)
    for seed in range(5):
        rng = make_rng(100 + seed)
        n = 60
        clauses = random_cnf(rng, n, int(4.3 * n))
        model = solve(clauses, n)
        if model is not None:
            assert satisfies(model, clauses)
    n, clauses = pigeonhole(6)
    assert solve(clauses, n) is None


def test_incremental_use():
    s = Solver()
    s.add_clause([1, 2])
    assert s.solve()
    s.add_clause([-1])
    assert s.solve() and s.model()[:2] == [-1, 2]
    s.add_clause([-2])
    assert not s.solve()
    assert not s.solve()
    assert s.add_clause([3]) is False


def test_model_before_solve_raises():
    with pytest.raises(RuntimeError):
        Solver().model()
