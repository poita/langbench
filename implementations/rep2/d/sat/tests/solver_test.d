module solver_test;

import sat.dimacs;
import sat.solver;

private SolveResult run(int n, const int[][] clauses, out bool[] model)
{
    Cnf cnf;
    cnf.numVars = n;
    foreach (c; clauses)
        cnf.add(c);
    const r = solveCnf(cnf, model);
    if (r == SolveResult.sat)
        assert(satisfies(cnf, model), "model does not satisfy the formula");
    return r;
}

unittest
{
    long[] seq;
    foreach (i; 0 .. 15)
        seq ~= luby(i);
    assert(seq == [1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8]);
}

unittest
{
    bool[] m;
    assert(run(0, [], m) == SolveResult.sat);
    assert(run(3, [], m) == SolveResult.sat && m.length == 3);
    assert(run(2, [[]], m) == SolveResult.unsat);
    assert(run(2, [[1, 2], []], m) == SolveResult.unsat);
    assert(run(1, [[1], [-1]], m) == SolveResult.unsat);
}

unittest
{
    bool[] m;
    // Tautologies count as satisfied; duplicate literals collapse.
    assert(run(2, [[1, -1, 2], [-2]], m) == SolveResult.sat);
    assert(!m[1]);
    assert(run(2, [[1, 1, 1], [-1, -1]], m) == SolveResult.unsat);
    // Unit chain decided by propagation alone.
    assert(run(4, [[1], [-1, 2], [-2, 3], [-3, -4]], m) == SolveResult.sat);
    assert(m == [true, true, true, false]);
}

unittest
{
    // Spec examples.
    bool[] m;
    assert(run(3, [[1, -2], [2, 3]], m) == SolveResult.sat);
    assert(run(2, [[1, 2], [-1, 2], [-1, -2], [1, -2]], m) == SolveResult.unsat);
}

unittest
{
    // Incremental API on the class itself.
    auto s = new Solver(3);
    assert(s.numVars == 3);
    assert(s.addClause([1, -2]));
    assert(s.addClause([2, 3]));
    assert(s.addClause([-3]));
    assert(s.solve() == SolveResult.sat);
    assert(s.modelValue(1) && s.modelValue(2) && !s.modelValue(3));

    auto t = new Solver(1);
    assert(t.addClause([1]));
    assert(!t.addClause([-1]));
    assert(t.solve() == SolveResult.unsat);

    import std.exception : assertThrown;
    assertThrown(new Solver(2).addClause([3]));
    assertThrown(new Solver(2).addClause([0]));
}

/// Pigeonhole PHP(n+1 pigeons, n holes): unsatisfiable, needs real learning.
private int[][] pigeonhole(int holes, out int nVars)
{
    const pigeons = holes + 1;
    nVars = pigeons * holes;
    int var(int p, int h) { return p * holes + h + 1; }
    int[][] cs;
    foreach (p; 0 .. pigeons)
    {
        int[] c;
        foreach (h; 0 .. holes)
            c ~= var(p, h);
        cs ~= c;
    }
    foreach (h; 0 .. holes)
        foreach (p; 0 .. pigeons)
            foreach (q; p + 1 .. pigeons)
                cs ~= [-var(p, h), -var(q, h)];
    return cs;
}

unittest
{
    foreach (holes; 2 .. 8)
    {
        int n;
        auto cs = pigeonhole(holes, n);
        bool[] m;
        assert(run(n, cs, m) == SolveResult.unsat);
    }
}

/// Deterministic pseudo-random 3-SAT; every model is re-checked.
unittest
{
    uint state = 12345;
    uint next() { state = state * 1103515245u + 12345u; return (state >> 8) & 0xffffff; }

    int sat, unsat;
    foreach (inst; 0 .. 40)
    {
        const n = 30;
        const m = 128; // ratio ~4.27
        int[][] cs;
        foreach (i; 0 .. m)
        {
            int[] c;
            foreach (k; 0 .. 3)
                c ~= cast(int)(next() % n + 1) * ((next() & 1) ? 1 : -1);
            cs ~= c;
        }
        bool[] model;
        const r = run(n, cs, model);
        r == SolveResult.sat ? ++sat : ++unsat;
    }
    assert(sat > 0 && unsat > 0);
}

unittest
{
    // Brute-force cross-check on tiny random formulas.
    uint state = 99;
    uint next() { state = state * 1664525u + 1013904223u; return state >> 8; }
    foreach (inst; 0 .. 300)
    {
        const n = 6;
        int[][] cs;
        foreach (i; 0 .. next() % 30)
        {
            int[] c;
            foreach (k; 0 .. 1 + next() % 3)
                c ~= cast(int)(next() % n + 1) * ((next() & 1) ? 1 : -1);
            cs ~= c;
        }
        bool expected = false;
        foreach (mask; 0 .. 1 << n)
        {
            bool all = true;
            foreach (c; cs)
            {
                bool any = false;
                foreach (l; c)
                {
                    const v = (l < 0 ? -l : l) - 1;
                    if ((((mask >> v) & 1) != 0) == (l > 0))
                        any = true;
                }
                if (!any)
                {
                    all = false;
                    break;
                }
            }
            if (all)
            {
                expected = true;
                break;
            }
        }
        bool[] model;
        assert((run(n, cs, model) == SolveResult.sat) == expected);
    }
}

unittest
{
    // A formula large enough to trigger restarts and clause-database
    // reduction: PHP(8) is far beyond 2000 learnt clauses.
    int n;
    auto cs = pigeonhole(8, n);
    Cnf cnf;
    cnf.numVars = n;
    foreach (c; cs)
        cnf.add(c);
    auto s = new Solver(n);
    assert(loadInto(cnf, s));
    assert(s.solve() == SolveResult.unsat);
    assert(s.conflicts > 2000);
}
