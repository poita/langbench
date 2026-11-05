/// Helpers shared by the unit tests (not part of the library).
module sat.testutil;

import sat;

/// Does `model` satisfy every clause of `cnf`?
bool satisfies(const ref Cnf cnf, const(bool)[] model)
{
    foreach (i; 0 .. cnf.numClauses)
    {
        bool ok = false;
        foreach (l; cnf.clause(i))
        {
            immutable v = l > 0 ? l : -l;
            if (model[v - 1] == (l > 0))
            {
                ok = true;
                break;
            }
        }
        if (!ok)
            return false;
    }
    return true;
}

/// Exhaustive satisfiability check (only for small variable counts).
bool bruteForce(const ref Cnf cnf)
{
    assert(cnf.numVars <= 20);
    auto model = new bool[cnf.numVars];
    foreach (mask; 0 .. (1UL << cnf.numVars))
    {
        foreach (v; 0 .. cnf.numVars)
            model[v] = ((mask >> v) & 1) != 0;
        if (satisfies(cnf, model))
            return true;
    }
    return false;
}

/// Small deterministic generator (xorshift) so tests are reproducible.
struct Rng
{
    ulong state = 88172645463325252UL;
    uint next()
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return cast(uint)(state >> 16);
    }
    uint below(uint n) { return next() % n; }
}

/// Random k-SAT-like formula; clause lengths in 1 .. maxLen, repeated
/// variables allowed (so duplicates and tautologies occur).
Cnf randomCnf(ref Rng rng, int numVars, int numClauses, int maxLen)
{
    Cnf cnf;
    cnf.numVars = numVars;
    foreach (c; 0 .. numClauses)
    {
        int[] lits;
        immutable len = 1 + rng.below(maxLen);
        foreach (k; 0 .. len)
        {
            int v = 1 + rng.below(numVars);
            lits ~= (rng.below(2) ? v : -v);
        }
        cnf.addClause(lits);
    }
    return cnf;
}

/// Pigeonhole formula PHP(n): n+1 pigeons, n holes (unsatisfiable).
Cnf pigeonhole(int n)
{
    Cnf cnf;
    cnf.numVars = (n + 1) * n;
    int x(int p, int h) { return p * n + h + 1; }
    foreach (p; 0 .. n + 1)
    {
        int[] c;
        foreach (h; 0 .. n)
            c ~= x(p, h);
        cnf.addClause(c);
    }
    foreach (h; 0 .. n)
        foreach (p; 0 .. n + 1)
            foreach (q; p + 1 .. n + 1)
                cnf.addClause(-x(p, h), -x(q, h));
    return cnf;
}
