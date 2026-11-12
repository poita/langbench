/// The CDCL solver.
module sat.solver;

import std.algorithm : max, sort, swap;
import std.math : abs;

import sat.dimacs : Cnf;
import sat.luby : luby;
import sat.order : VarOrder;
import sat.types;
import sat.vec : Vec;

/// A stored (input or learnt) clause. `lits[0]` and `lits[1]` are the watched literals.
final class Clause
{
    Lit[] lits;
    double activity = 0.0;
    bool learnt;
    bool removed;

    this(Lit[] lits, bool learnt) pure nothrow @safe
    {
        this.lits = lits;
        this.learnt = learnt;
    }
}

/// Counters describing a run of the solver.
struct Stats
{
    ulong conflicts;
    ulong decisions;
    ulong propagations;
    ulong restarts;
    ulong reductions;
    ulong learntClauses;
}

/// The outcome of $(D solve(Cnf)).
struct Solution
{
    /// Whether the formula is satisfiable.
    bool satisfiable;
    /// When satisfiable: the value of each variable (index 0 is variable 1).
    bool[] model;
}

/**
 * A conflict-driven clause-learning SAT solver in the style of MiniSat.
 *
 * $(UL
 *   $(LI unit propagation with two watched literals (and a blocker literal),)
 *   $(LI first-UIP conflict analysis with local clause minimisation,)
 *   $(LI VSIDS branching (see $(D VarOrder)) with phase saving, initial phase false,)
 *   $(LI restarts on the Luby sequence, `100 * luby(2, i)` conflicts for restart `i`,)
 *   $(LI periodic deletion of the less active half of the learnt clauses.)
 * )
 *
 * Add clauses with $(D addClause), then call $(D solve). A solver is meant
 * to be solved once; clauses must be added before solving.
 *
 * Example:
 * ---
 * auto s = new Solver;
 * s.addClause([1, -2]);
 * s.addClause([2, 3]);
 * if (s.solve())
 *     writeln(s.model);   // e.g. [false, false, true]
 * ---
 */
final class Solver
{
    private enum byte vFalse = 0, vTrue = 1, vUndef = 2;

    private
    {
        bool ok = true; // false once the clause set is known to be unsatisfiable
        byte[] assigns; // per variable: vFalse / vTrue / vUndef
        int[] level;
        Clause[] reason;
        bool[] phase; // saved phase: true = last assigned true
        ubyte[] seen;

        Vec!Lit trail;
        Vec!int trailLim;
        size_t qhead;

        Clause[] clauses;
        Clause[] learnts;
        Vec!Watcher[] watches; // indexed by literal p: clauses to visit when p becomes true

        VarOrder order;
        double claInc = 1.0;
        double maxLearnts = 0;

        bool[] modelValues;
        Stats counters;
    }

    private struct Watcher
    {
        Clause clause;
        Lit blocker;
    }

    /// Creates a solver with `numVars` variables (more are created on demand by $(D addClause)).
    this(int numVars = 0)
    {
        foreach (_; 0 .. numVars)
            newVar();
    }

    /// Adds a variable and returns its 0-based index.
    int newVar()
    {
        immutable v = cast(int) assigns.length;
        assigns ~= vUndef;
        level ~= 0;
        reason ~= null;
        phase ~= false;
        seen ~= 0;
        watches ~= Vec!Watcher.init;
        watches ~= Vec!Watcher.init;
        order.addVariable();
        return v;
    }

    /// Number of variables.
    int numVars() const pure nothrow @nogc @safe { return cast(int) assigns.length; }

    /// Number of stored input clauses (after root simplification).
    size_t numClauses() const pure nothrow @nogc @safe { return clauses.length; }

    /// Number of learnt clauses currently kept.
    size_t numLearnts() const pure nothrow @nogc @safe { return learnts.length; }

    /// Counters for the run so far.
    Stats stats() const pure nothrow @nogc @safe { return counters; }

    /// False once the clauses added so far are known to be unsatisfiable.
    bool okay() const pure nothrow @nogc @safe { return ok; }

    /**
     * Adds a clause given as DIMACS integers (`k` / `-k`, never 0), creating
     * variables as needed.
     *
     * The clause is simplified at the root: duplicate literals are merged,
     * tautologies and clauses already satisfied are dropped, falsified
     * literals are removed, and a resulting unit is assigned and propagated at
     * level 0. An empty result makes the solver unsatisfiable.
     *
     * Returns: `false` if the solver is now known to be unsatisfiable.
     */
    bool addClause(const(int)[] dimacsLits)
    {
        if (!ok)
            return false;
        assert(decisionLevel == 0, "clauses must be added at level 0");

        auto lits = new Lit[dimacsLits.length];
        foreach (i, d; dimacsLits)
        {
            while (abs(d) > numVars)
                newVar();
            lits[i] = fromDimacs(d);
        }
        lits.sort();

        size_t j = 0;
        Lit prev = litUndef;
        foreach (l; lits)
        {
            immutable val = litValue(l);
            if (val == vTrue || l == negate(prev))
                return true; // satisfied at the root, or a tautology
            if (val != vFalse && l != prev)
            {
                lits[j++] = l;
                prev = l;
            }
        }
        lits = lits[0 .. j];

        if (lits.length == 0)
            return ok = false;
        if (lits.length == 1)
        {
            enqueue(lits[0], null);
            return ok = (propagate() is null);
        }
        auto c = new Clause(lits, false);
        clauses ~= c;
        attach(c);
        return true;
    }

    /**
     * Searches for a satisfying assignment.
     *
     * Returns: `true` if the clauses are satisfiable (read the assignment with
     * $(D model)), `false` if they are not.
     */
    bool solve()
    {
        if (!ok)
            return false;
        maxLearnts = max(cast(double) (clauses.length / 3), 2000.0);

        for (long restart = 0;; ++restart)
        {
            immutable budget = 100 * luby(2, restart);
            immutable status = search(budget);
            if (status == vTrue)
            {
                modelValues = new bool[numVars];
                foreach (v; 0 .. numVars)
                    modelValues[v] = assigns[v] == vTrue;
                cancelUntil(0);
                return true;
            }
            if (status == vFalse)
            {
                ok = false;
                return false;
            }
            // Restart: we are at level 0.
            ++counters.restarts;
            if (learnts.length >= maxLearnts)
            {
                reduceDB();
                maxLearnts *= 1.1;
            }
        }
    }

    /// The satisfying assignment found by the last successful $(D solve): index `v` is variable `v + 1`.
    const(bool)[] model() const pure nothrow @nogc @safe { return modelValues; }

private:
    int decisionLevel() const pure nothrow @nogc @safe { return cast(int) trailLim.length; }

    /// 1 if true, 0 if false, >= 2 if unassigned.
    int litValue(Lit l) const pure nothrow @nogc @safe
    {
        return assigns[variableOf(l)] ^ (l & 1);
    }

    void attach(Clause c) pure nothrow @safe
    {
        watches[negate(c.lits[0])].push(Watcher(c, c.lits[1]));
        watches[negate(c.lits[1])].push(Watcher(c, c.lits[0]));
    }

    void enqueue(Lit l, Clause from) pure nothrow @safe
    {
        immutable v = variableOf(l);
        assigns[v] = isNegative(l) ? vFalse : vTrue;
        level[v] = decisionLevel;
        reason[v] = from;
        trail.push(l);
    }

    /// Undoes all assignments above decision level `lvl`, saving phases.
    void cancelUntil(int lvl) pure nothrow @safe
    {
        if (decisionLevel <= lvl)
            return;
        immutable stop = trailLim[lvl];
        foreach_reverse (i; stop .. trail.length)
        {
            immutable v = variableOf(trail[i]);
            phase[v] = assigns[v] == vTrue;
            assigns[v] = vUndef;
            reason[v] = null;
            order.insert(v);
        }
        trail.shrink(stop);
        trailLim.shrink(lvl);
        qhead = stop;
    }

    /// Unit propagation. Returns a conflicting clause or null.
    Clause propagate() pure nothrow @safe
    {
        Clause conflict = null;
        while (qhead < trail.length)
        {
            immutable p = trail[qhead++]; // p is true
            immutable falseLit = negate(p);
            ++counters.propagations;
            auto ws = watches[p][]; // aliases the live storage of this list
            size_t i = 0, j = 0;
            immutable n = ws.length;
            while (i < n)
            {
                auto w = ws[i++];
                if (litValue(w.blocker) == vTrue)
                {
                    ws[j++] = w;
                    continue;
                }
                auto c = w.clause;
                if (c.removed)
                    continue;
                auto lits = c.lits;
                if (lits[0] == falseLit)
                {
                    lits[0] = lits[1];
                    lits[1] = falseLit;
                }
                immutable first = lits[0];
                auto keep = Watcher(c, first);
                if (first != w.blocker && litValue(first) == vTrue)
                {
                    ws[j++] = keep;
                    continue;
                }
                // Look for a new literal to watch.
                bool found = false;
                foreach (k; 2 .. lits.length)
                {
                    if (litValue(lits[k]) != vFalse)
                    {
                        lits[1] = lits[k];
                        lits[k] = falseLit;
                        watches[negate(lits[1])].push(keep);
                        found = true;
                        break;
                    }
                }
                if (found)
                    continue;
                // Clause is unit or conflicting under the current assignment.
                ws[j++] = keep;
                if (litValue(first) == vFalse)
                {
                    conflict = c;
                    qhead = trail.length;
                    while (i < n)
                        ws[j++] = ws[i++];
                }
                else
                {
                    enqueue(first, c);
                }
            }
            watches[p].shrink(j);
            if (conflict !is null)
                break;
        }
        return conflict;
    }

    void bumpClause(Clause c) pure nothrow @safe
    {
        c.activity += claInc;
        if (c.activity > 1e20)
        {
            foreach (l; learnts)
                l.activity *= 1e-20;
            claInc *= 1e-20;
        }
    }

    /// First-UIP analysis of `confl`: fills `learnt` (asserting literal first) and returns the backjump level.
    int analyze(Clause confl, ref Lit[] learnt) pure nothrow @safe
    {
        learnt.length = 1;
        int pathCount = 0;
        Lit p = litUndef;
        size_t index = trail.length;

        do
        {
            if (confl.learnt)
                bumpClause(confl);
            foreach (q; confl.lits[(p == litUndef) ? 0 : 1 .. $])
            {
                immutable v = variableOf(q);
                if (seen[v] == 0 && level[v] > 0)
                {
                    order.bump(v);
                    seen[v] = 1;
                    if (level[v] >= decisionLevel)
                        ++pathCount;
                    else
                        learnt ~= q;
                }
            }
            while (seen[variableOf(trail[--index])] == 0) {}
            p = trail[index];
            confl = reason[variableOf(p)];
            seen[variableOf(p)] = 0;
            --pathCount;
        }
        while (pathCount > 0);
        learnt[0] = negate(p);

        // Local minimisation: drop a literal whose reason is entirely covered by the clause.
        auto toClear = learnt.dup;
        size_t j = 1;
        foreach (i; 1 .. learnt.length)
        {
            immutable v = variableOf(learnt[i]);
            auto r = reason[v];
            bool keep = true;
            if (r !is null)
            {
                keep = false;
                foreach (q; r.lits[1 .. $])
                {
                    immutable u = variableOf(q);
                    if (seen[u] == 0 && level[u] > 0)
                    {
                        keep = true;
                        break;
                    }
                }
            }
            if (keep)
                learnt[j++] = learnt[i];
        }
        learnt.length = j;
        foreach (l; toClear)
            seen[variableOf(l)] = 0;

        if (learnt.length == 1)
            return 0;
        size_t maxI = 1;
        foreach (i; 2 .. learnt.length)
            if (level[variableOf(learnt[i])] > level[variableOf(learnt[maxI])])
                maxI = i;
        swap(learnt[1], learnt[maxI]);
        return level[variableOf(learnt[1])];
    }

    /// Deletes the lower-activity half of the learnt clauses, keeping binary ones.
    void reduceDB()
    {
        ++counters.reductions;
        learnts.sort!((a, b) => a.activity < b.activity);
        immutable half = learnts.length / 2;
        size_t j = 0;
        foreach (i, c; learnts)
        {
            if (i < half && c.lits.length > 2)
                c.removed = true;
            else
                learnts[j++] = c;
        }
        learnts = learnts[0 .. j];
        foreach (ref ws; watches)
        {
            auto s = ws[];
            size_t k = 0;
            foreach (w; s)
                if (!w.clause.removed)
                    s[k++] = w;
            ws.shrink(k);
        }
    }

    /// Runs CDCL until a model, a refutation, or `budget` conflicts. Returns vTrue / vFalse / vUndef.
    byte search(long budget)
    {
        long conflictsHere = 0;
        Lit[] learnt;
        for (;;)
        {
            auto confl = propagate();
            if (confl !is null)
            {
                ++counters.conflicts;
                ++conflictsHere;
                if (decisionLevel == 0)
                    return vFalse;
                immutable back = analyze(confl, learnt);
                cancelUntil(back);
                if (learnt.length == 1)
                {
                    enqueue(learnt[0], null);
                }
                else
                {
                    auto c = new Clause(learnt.dup, true);
                    learnts ~= c;
                    attach(c);
                    bumpClause(c);
                    enqueue(learnt[0], c);
                }
                ++counters.learntClauses;
                order.decay();
                claInc /= 0.999;
            }
            else
            {
                if (conflictsHere >= budget)
                {
                    cancelUntil(0);
                    return vUndef;
                }
                int next = -1;
                while (!order.empty)
                {
                    immutable v = order.removeMax();
                    if (assigns[v] == vUndef)
                    {
                        next = v;
                        break;
                    }
                }
                if (next < 0)
                    return vTrue; // every variable is assigned
                ++counters.decisions;
                trailLim.push(cast(int) trail.length);
                enqueue(mkLit(next, !phase[next]), null);
            }
        }
    }
}

/// Solves a parsed formula in one call.
Solution solve(const ref Cnf cnf)
{
    auto s = new Solver(cnf.numVars);
    foreach (clause; cnf.clauses)
        if (!s.addClause(clause))
            return Solution(false, null);
    if (!s.solve())
        return Solution(false, null);
    return Solution(true, s.model.dup);
}

version (unittest)
{
    import sat.dimacs : parseDimacs, satisfies;

    private bool bruteForce(const ref Cnf cnf)
    {
        foreach (mask; 0 .. 1UL << cnf.numVars)
        {
            bool[] m = new bool[cnf.numVars];
            foreach (v; 0 .. cnf.numVars)
                m[v] = ((mask >> v) & 1) != 0;
            if (satisfies(cnf, m))
                return true;
        }
        return false;
    }

    private Cnf pigeonhole(int holes)
    {
        immutable pigeons = holes + 1;
        Cnf cnf;
        cnf.numVars = pigeons * holes;
        int var(int p, int h) { return p * holes + h + 1; }
        foreach (p; 0 .. pigeons)
        {
            int[] c;
            foreach (h; 0 .. holes)
                c ~= var(p, h);
            cnf.clauses ~= c;
        }
        foreach (h; 0 .. holes)
            foreach (p; 0 .. pigeons)
                foreach (q; p + 1 .. pigeons)
                    cnf.clauses ~= [-var(p, h), -var(q, h)];
        return cnf;
    }
}

unittest
{
    auto cnf = parseDimacs("p cnf 3 2\n1 -2 0\n2 3 0\n");
    auto r = solve(cnf);
    assert(r.satisfiable && satisfies(cnf, r.model));
}

unittest
{
    // Packed and split clauses: unsatisfiable.
    auto cnf = parseDimacs("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0\n");
    assert(!solve(cnf).satisfiable);
}

unittest
{
    // Trivial cases.
    auto empty = parseDimacs("p cnf 0 0\n");
    auto r = solve(empty);
    assert(r.satisfiable && r.model.length == 0);

    auto noClauses = parseDimacs("p cnf 4 0\n");
    r = solve(noClauses);
    assert(r.satisfiable && r.model.length == 4);

    auto emptyClause = parseDimacs("p cnf 2 2\n1 2 0\n0\n");
    assert(!solve(emptyClause).satisfiable);

    auto units = parseDimacs("p cnf 2 2\n1 0\n-1 0\n");
    assert(!solve(units).satisfiable);
}

unittest
{
    // Duplicates and tautologies.
    auto cnf = parseDimacs("p cnf 2 3\n1 1 -2 0\n1 -1 0\n-1 -1 0\n");
    auto r = solve(cnf);
    assert(r.satisfiable && satisfies(cnf, r.model));
    assert(!r.model[0] && !r.model[1]);

    auto taut = parseDimacs("p cnf 1 1\n1 -1 0\n");
    assert(solve(taut).satisfiable);
}

unittest
{
    // Unit chain is decided by propagation alone.
    auto cnf = parseDimacs("p cnf 4 4\n1 0\n-1 2 0\n-2 3 0\n-3 -4 0\n");
    auto r = solve(cnf);
    assert(r.satisfiable && r.model == [true, true, true, false]);
}

unittest
{
    // One long clause.
    Cnf cnf;
    cnf.numVars = 1000;
    int[] c;
    foreach (i; 1 .. 1001)
        c ~= i;
    cnf.clauses ~= c;
    auto r = solve(cnf);
    assert(r.satisfiable && satisfies(cnf, r.model));
}

unittest
{
    // Pigeonhole: n+1 pigeons in n holes is unsatisfiable; n pigeons fit.
    foreach (h; 2 .. 7)
    {
        auto cnf = pigeonhole(h);
        assert(!solve(cnf).satisfiable);
    }
    auto fits = pigeonhole(5);
    fits.clauses = fits.clauses[1 .. $]; // drop one pigeon's "must sit somewhere"
    auto r = solve(fits);
    assert(r.satisfiable && satisfies(fits, r.model));
}

unittest
{
    // Random small formulas agree with brute force.
    uint state = 2024;
    uint next() { state = state * 1664525 + 1013904223; return state >> 8; }

    foreach (round; 0 .. 400)
    {
        Cnf cnf;
        cnf.numVars = 3 + next() % 8;
        immutable m = next() % (cnf.numVars * 6);
        foreach (_; 0 .. m)
        {
            int[] c;
            foreach (_k; 0 .. 1 + next() % 4)
            {
                immutable v = 1 + cast(int) (next() % cnf.numVars);
                c ~= (next() & 1) ? v : -v;
            }
            cnf.clauses ~= c;
        }
        auto r = solve(cnf);
        assert(r.satisfiable == bruteForce(cnf));
        if (r.satisfiable)
            assert(satisfies(cnf, r.model));
    }
}

unittest
{
    // Random 3-SAT near the threshold exercises learning, restarts and reduction.
    uint state = 7;
    uint next() { state = state * 1664525 + 1013904223; return state >> 8; }

    int sat, unsat;
    foreach (round; 0 .. 12)
    {
        Cnf cnf;
        cnf.numVars = 100;
        foreach (_; 0 .. 426)
        {
            int[] c;
            foreach (_k; 0 .. 3)
            {
                immutable v = 1 + cast(int) (next() % 100);
                c ~= (next() & 1) ? v : -v;
            }
            cnf.clauses ~= c;
        }
        auto r = solve(cnf);
        if (r.satisfiable)
        {
            assert(satisfies(cnf, r.model));
            ++sat;
        }
        else
            ++unsat;
    }
    assert(sat + unsat == 12);
}

unittest
{
    // A tiny learnt-clause limit is not configurable, but a hard instance must still finish and count work.
    auto cnf = pigeonhole(7);
    auto s = new Solver(cnf.numVars);
    foreach (c; cnf.clauses)
        s.addClause(c);
    assert(!s.solve());
    assert(s.stats.conflicts > 0 && s.stats.restarts > 0);
    assert(s.stats.reductions > 0); // PHP(7) needs enough conflicts to trigger clause deletion
    assert(!s.okay);
}
