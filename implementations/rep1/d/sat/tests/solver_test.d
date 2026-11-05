module tests.solver_test;

import sat;
import tests.helpers;

@("empty formula is satisfiable")
unittest
{
    assert(solveChecked(0, []) == Result.sat);
    assert(solveChecked(5, []) == Result.sat);
}

@("empty clause is unsatisfiable")
unittest
{
    assert(solveChecked(3, [[1, 2], [], [-1]]) == Result.unsat);
    auto s = new Solver(1);
    assert(!s.addClause([]));
    assert(!s.addClause([1])); // ignored once unsat
    assert(s.solve() == Result.unsat);
}

@("unit propagation and conflicts at the root")
unittest
{
    assert(solveChecked(3, [[1], [-1, 2], [-2, 3]]) == Result.sat);
    assert(solveChecked(2, [[1], [-1, 2], [-2]]) == Result.unsat);
    assert(solveChecked(1, [[1], [-1]]) == Result.unsat);
}

@("duplicate literals and tautologies")
unittest
{
    assert(solveChecked(2, [[1, 1, -2], [1, -1], [-1, -1]]) == Result.sat);
    auto s = new Solver(2);
    assert(s.addClause([1, -1])); // tautology is dropped
    assert(s.numStoredClauses == 0);
    assert(s.addClause([2, 2, 1]));
    assert(s.numStoredClauses == 1);
    assert(solveChecked(1, [[1, -1], [1], [-1, -1]]) == Result.unsat);
}

@("clauses already satisfied or reduced at the root")
unittest
{
    auto s = new Solver(3);
    s.addClause([1]);
    s.addClause([1, 2, 3]); // satisfied, not stored
    assert(s.numStoredClauses == 0);
    s.addClause([-1, 2, 3]); // becomes (2 3)
    assert(s.numStoredClauses == 1);
    s.addClause([-2]);
    assert(s.solve() == Result.sat);
    assert(s.modelValue(0) && !s.modelValue(1) && s.modelValue(2));
}

@("the first example from the specification")
unittest
{
    auto s = new Solver(3);
    s.addClause([1, -2]);
    s.addClause([2, 3]);
    assert(s.solve() == Result.sat);
    assert(solveChecked(3, [[1, -2], [2, 3]]) == Result.sat);
}

@("unused variables get some value")
unittest
{
    auto s = new Solver(10);
    s.addClause([3]);
    assert(s.solve() == Result.sat);
    assert(s.modelValue(2));
}

@("single long clause")
unittest
{
    int[] big;
    foreach (i; 1 .. 1001)
        big ~= -i;
    assert(solveChecked(1000, [big]) == Result.sat);
}

@("literals out of range are rejected")
unittest
{
    import std.exception : assertThrown;

    auto s = new Solver(2);
    assertThrown(s.addClause([3]));
    assertThrown(s.addClause([0]));
}

@("pigeonhole formulas are unsatisfiable")
unittest
{
    foreach (p; 1 .. 7)
        assert(solveChecked(p * (p + 1), pigeonhole(p)) == Result.unsat);
}

@("pigeonhole with a free pigeon removed is satisfiable")
unittest
{
    auto cs = pigeonhole(4);
    cs = cs[1 .. $]; // drop pigeon 0's "some hole" clause
    assert(solveChecked(20, cs) == Result.sat);
}

@("random 3-SAT agrees with brute force")
unittest
{
    int sat_count, unsat_count;
    foreach (seed; 1 .. 120)
    {
        enum n = 12;
        auto cs = random3Sat(n, 51, seed);
        const r = solveChecked(n, cs);
        assert((r == Result.sat) == bruteForce(n, cs));
        if (r == Result.sat)
            sat_count++;
        else
            unsat_count++;
    }
    assert(sat_count > 10 && unsat_count > 10, "test set should mix both outcomes");
}

@("larger random 3-SAT near the threshold gives valid models")
unittest
{
    foreach (seed; 1 .. 6)
        solveChecked(100, random3Sat(100, 426, seed));
}

@("search is deterministic")
unittest
{
    auto cs = random3Sat(80, 340, 7);
    bool[] model(ref Result r)
    {
        auto s = new Solver(80);
        foreach (c; cs)
            s.addClause(c);
        r = s.solve();
        bool[] m;
        if (r == Result.sat)
            foreach (v; 0 .. 80)
                m ~= s.modelValue(v);
        return m;
    }

    Result r1, r2;
    assert(model(r1) == model(r2) && r1 == r2);
}

@("learnt-clause reduction path keeps answers correct")
unittest
{
    // Enough conflicts to trigger at least one reduction (max_learnts starts at 2000).
    auto s = new Solver(72);
    foreach (c; pigeonhole(8))
        s.addClause(c);
    assert(s.solve() == Result.unsat);
}
