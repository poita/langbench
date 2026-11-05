/// Shared helpers for the unit tests (not part of the library).
module tests.helpers;

import sat;

/// Check that `s`' model satisfies every clause of `clauses` (DIMACS literals).
bool modelSatisfies(const Solver s, const int[][] clauses)
{
    foreach (c; clauses)
    {
        bool any = false;
        foreach (l; c)
        {
            const v = (l > 0 ? l : -l) - 1;
            if (s.modelValue(v) == (l > 0))
            {
                any = true;
                break;
            }
        }
        if (!any)
            return false;
    }
    return true;
}

/// Solve `clauses` over `n` variables; return the verdict, and assert any model is correct.
Result solveChecked(int n, const int[][] clauses)
{
    auto s = new Solver(n);
    foreach (c; clauses)
        s.addClause(c);
    const r = s.solve();
    if (r == Result.sat)
        assert(modelSatisfies(s, clauses), "model does not satisfy the formula");
    return r;
}

/// Deterministic xorshift generator for reproducible random formulas.
struct Rng
{
    ulong state = 88172645463325252UL;
    uint next() @safe nothrow @nogc
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return cast(uint)(state >> 16);
    }
}

/// Random 3-SAT with `n` variables and `m` clauses of three distinct variables.
int[][] random3Sat(int n, int m, ulong seed)
{
    auto rng = Rng(seed * 2654435761UL + 1);
    int[][] cs;
    foreach (_; 0 .. m)
    {
        int[] c;
        while (c.length < 3)
        {
            int v = cast(int)(rng.next() % n) + 1;
            bool dup = false;
            foreach (x; c)
                if (x == v || x == -v)
                    dup = true;
            if (!dup)
                c ~= (rng.next() & 1) ? v : -v;
        }
        cs ~= c;
    }
    return cs;
}

/// Pigeonhole formula PHP(p): p+1 pigeons, p holes (unsatisfiable).
int[][] pigeonhole(int p)
{
    int var(int pigeon, int hole) => pigeon * p + hole + 1;
    int[][] cs;
    foreach (i; 0 .. p + 1)
    {
        int[] c;
        foreach (h; 0 .. p)
            c ~= var(i, h);
        cs ~= c;
    }
    foreach (h; 0 .. p)
        foreach (i; 0 .. p + 1)
            foreach (j; i + 1 .. p + 1)
                cs ~= [-var(i, h), -var(j, h)];
    return cs;
}

/// Brute-force satisfiability for small `n`.
bool bruteForce(int n, const int[][] clauses)
{
    foreach (mask; 0 .. 1UL << n)
    {
        bool all = true;
        foreach (c; clauses)
        {
            bool any = false;
            foreach (l; c)
            {
                const v = (l > 0 ? l : -l) - 1;
                if ((((mask >> v) & 1) != 0) == (l > 0))
                {
                    any = true;
                    break;
                }
            }
            if (!any)
            {
                all = false;
                break;
            }
        }
        if (all)
            return true;
    }
    return false;
}
