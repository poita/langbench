module sat.solver_test;

import sat;
import sat.testutil;

private SolveResult run(string dimacs)
{
    auto cnf = parseDimacs(dimacs);
    auto r = solve(cnf);
    if (r.satisfiable)
    {
        assert(r.model.length == cnf.numVars);
        assert(satisfies(cnf, r.model));
    }
    return r;
}

unittest // trivial formulas
{
    assert(run("p cnf 0 0\n").satisfiable);
    assert(run("p cnf 5 0\n").satisfiable);
    assert(run("p cnf 5 0\n").model.length == 5);
    assert(!run("p cnf 1 1\n0\n").satisfiable);
    assert(!run("p cnf 2 3\n1 2 0\n0\n-1 0\n").satisfiable);
}

unittest // units and propagation at the root
{
    auto r = run("p cnf 3 3\n1 0\n-1 2 0\n-2 3 0\n");
    assert(r.satisfiable && r.model == [true, true, true]);
    assert(!run("p cnf 1 2\n1 0\n-1 0\n").satisfiable);
    assert(!run("p cnf 3 4\n1 0\n-1 2 0\n-2 3 0\n-3 0\n").satisfiable);
}

unittest // duplicates and tautologies
{
    assert(run("p cnf 2 1\n1 1 1 0\n").model[0]);
    assert(run("p cnf 1 1\n1 -1 0\n").satisfiable);
    // tautology must count as satisfied, not be stripped to (2)
    auto r = run("p cnf 3 4\n1 1 -1 -1 2 0\n-2 0\n1 3 0\n-1 3 0\n");
    assert(r.satisfiable && !r.model[1]);
    assert(!run("p cnf 1 3\n1 -1 0\n1 0\n-1 1 -1 0\n-1 0\n").satisfiable);
}

unittest // all eight clauses over three variables vs. seven of them
{
    string all = "p cnf 3 8\n";
    foreach (m; 0 .. 8)
        all ~= ((m & 1) ? "-1 " : "1 ") ~ ((m & 2) ? "-2 " : "2 ") ~ ((m & 4) ? "-3 " : "3 ") ~ "0\n";
    assert(!run(all).satisfiable);
    auto seven = "p cnf 3 7\n" ~ all[10 .. $ - 8];   // drop the header and the last clause
    assert(run(seven).satisfiable);
}

unittest // pigeonhole formulas are unsatisfiable
{
    foreach (n; 1 .. 7)
    {
        auto cnf = pigeonhole(n);
        assert(!solve(cnf).satisfiable);
    }
}

unittest // random formulas agree with brute force and models are valid
{
    Rng rng;
    int nSat, nUnsat;
    foreach (iter; 0 .. 400)
    {
        immutable nv = 3 + rng.below(10);
        immutable nc = nv * 2 + rng.below(nv * 3);
        auto cnf = randomCnf(rng, nv, nc, 4);
        auto r = solve(cnf);
        assert(r.satisfiable == bruteForce(cnf));
        if (r.satisfiable)
        {
            assert(satisfies(cnf, r.model));
            ++nSat;
        }
        else
            ++nUnsat;
    }
    assert(nSat > 20 && nUnsat > 20); // the generator exercises both outcomes
}

unittest // random 3-SAT near the threshold (exercises learning and restarts)
{
    Rng rng;
    int nSat, nUnsat;
    foreach (iter; 0 .. 12)
    {
        Cnf cnf;
        enum nv = 60;
        cnf.numVars = nv;
        foreach (c; 0 .. 256)
        {
            int[3] l;
            foreach (k; 0 .. 3)
            {
                immutable v = 1 + rng.below(nv);
                l[k] = rng.below(2) ? v : -v;
            }
            cnf.addClause(l[]);
        }
        auto r = solve(cnf);
        if (r.satisfiable)
        {
            assert(satisfies(cnf, r.model));
            ++nSat;
        }
        else
            ++nUnsat;
    }
    assert(nSat + nUnsat == 12);
}

unittest // the solver is deterministic
{
    auto cnf = pigeonhole(5);
    auto a = new Solver(cnf.numVars);
    auto b = new Solver(cnf.numVars);
    foreach (i; 0 .. cnf.numClauses)
    {
        a.addClause(cnf.clause(i));
        b.addClause(cnf.clause(i));
    }
    assert(!a.solve() && !b.solve());
    assert(a.stats.conflicts == b.stats.conflicts && a.stats.conflicts > 0);
}

unittest // direct Solver API
{
    auto s = new Solver(3);
    assert(s.numVars == 3 && s.isConsistent);
    assert(s.addClause([1, -2]));
    assert(s.addClause([2, 3]));
    assert(s.solve());
    auto m = s.model;
    assert(m.length == 3 && (m[0] || !m[1]) && (m[1] || m[2]));

    auto t = new Solver(1);
    assert(t.addClause([1]));
    assert(!t.addClause([-1]));      // contradiction found while adding
    assert(!t.isConsistent);
    assert(!t.addClause([1]));       // later clauses are ignored
    assert(!t.solve());
}

unittest // large clause databases: enough conflicts to trigger learnt-clause reduction
{
    auto cnf = pigeonhole(8);
    auto s = new Solver(cnf.numVars);
    foreach (i; 0 .. cnf.numClauses)
        s.addClause(cnf.clause(i));
    assert(!s.solve());
    assert(s.stats.reductions > 0);
}
