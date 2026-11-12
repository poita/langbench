/**
 * The CDCL solver.
 *
 * A MiniSat-style conflict-driven clause-learning solver: two watched
 * literals, first-UIP learning with local clause minimisation, VSIDS
 * branching with phase saving, Luby restarts, and activity-based deletion of
 * learnt clauses.
 */
module sat.solver;

import std.algorithm : sort, swap;
import sat.clause;
import sat.order;
import sat.types;

/// Counters describing the work done by a $(D Solver).
struct Stats
{
    ulong conflicts;
    ulong decisions;
    ulong propagations;
    ulong restarts;
    ulong learntsDeleted;
}

/// Outcome of $(D Solver.solve).
enum SolveStatus
{
    unsat,
    sat,
}

/**
 * The `i`-th (zero-based) element of the Luby sequence scaled by `y`:
 * `y^k` where the sequence of exponents is 0 0 1 0 0 1 2 0 0 1 0 0 1 2 3 ...
 */
double luby(double y, int i) pure nothrow @nogc @safe
{
    int size = 1, seq = 0;
    while (size < i + 1)
    {
        seq++;
        size = 2 * size + 1;
    }
    while (size - 1 != i)
    {
        size = (size - 1) >> 1;
        seq--;
        i = i % size;
    }
    double r = 1;
    foreach (_; 0 .. seq)
        r *= y;
    return r;
}

private struct Watcher
{
    Clause clause;
    Lit blocker;
}

/// A growable watcher list that keeps its storage when shrunk.
private struct WatchList
{
    Watcher[] data;
    size_t len;

    void push(Watcher w) pure nothrow @safe
    {
        if (len == data.length)
            data.length = len == 0 ? 4 : len * 2;
        data[len++] = w;
    }
}

/**
 * An incremental-in-clauses CDCL SAT solver.
 *
 * Add clauses with $(D addClause) (variables are created on demand), then call
 * $(D solve) once. After a `sat` result, $(D model) holds a satisfying
 * assignment.
 */
final class Solver
{
    private
    {
        // assignment state
        ubyte[] litVal;           // per literal: 0 false, 1 true, 2 undef
        int[] level;              // per variable
        Clause[] reason;          // per variable
        bool[] polarity;          // saved phase: true means the last value was false
        Lit[] trail;
        size_t[] trailLim;
        size_t qhead;

        WatchList[] watches;      // indexed by literal: clauses watching ~lit
        Clause[] clauses;         // original (stored) clauses
        Clause[] learnts;
        VarOrder order;

        bool ok = true;           // false once the formula is known unsat
        double claInc = 1.0;
        double maxLearnts = 0;
        ubyte[] seen;
        bool[] modelVals;
        Stats st;
    }

    /// Lower bound on the initial learnt-clause limit (default 2000); the
    /// limit starts at `max(numClauses / 3, minLearnts)`. Set before `solve`.
    size_t minLearnts = 2000;

    /// Creates a solver with `numVars` variables.
    this(int numVars = 0)
    {
        foreach (_; 0 .. numVars)
            newVar();
    }

    /// Number of variables.
    int numVars() const pure nothrow @nogc @safe { return cast(int) level.length; }

    /// Work counters.
    ref const(Stats) stats() const pure nothrow @nogc @safe { return st; }

    /// Number of stored original clauses (size >= 2 after root simplification).
    size_t numClauses() const pure nothrow @nogc @safe { return clauses.length; }

    /// Number of learnt clauses currently held.
    size_t numLearnts() const pure nothrow @nogc @safe { return learnts.length; }

    /// Creates a new variable and returns its zero-based index.
    int newVar() pure nothrow @safe
    {
        const v = cast(int) level.length;
        litVal ~= 2;
        litVal ~= 2;
        level ~= 0;
        reason ~= null;
        polarity ~= true; // initial phase: false
        seen ~= 0;
        watches ~= WatchList.init;
        watches ~= WatchList.init;
        order.addVar();
        return v;
    }

    /**
     * Adds a clause given as non-zero DIMACS literals (`k` / `-k`, `k >= 1`).
     * Variables beyond the current count are created.
     *
     * Returns: false if the formula is now known to be unsatisfiable.
     */
    bool addClause(const(int)[] dimacs)
    {
        Lit[] ls;
        ls.reserve(dimacs.length);
        foreach (d; dimacs)
        {
            const l = Lit.fromDimacs(d);
            while (l.var >= numVars)
                newVar();
            ls ~= l;
        }
        return addClause(ls);
    }

    /// ditto
    bool addClause(Lit[] ls)
    in (decisionLevel == 0)
    {
        if (!ok)
            return false;
        // Simplify at the root: sort, drop duplicates, detect tautologies and
        // root-satisfied clauses, remove root-false literals.
        ls = ls.dup;
        ls.sort!((a, b) => a.x < b.x);
        size_t j = 0;
        Lit prev = litUndef;
        foreach (l; ls)
        {
            const v = value(l);
            if (v == LBool.True || (!prev.isUndef && l == ~prev))
                return true; // satisfied or tautology
            if (v != LBool.False && l != prev)
            {
                ls[j++] = l;
                prev = l;
            }
        }
        ls = ls[0 .. j];
        if (ls.length == 0)
            return ok = false;
        if (ls.length == 1)
        {
            uncheckedEnqueue(ls[0], null);
            return ok = (propagate() is null);
        }
        auto c = new Clause(ls, false);
        clauses ~= c;
        attach(c);
        return true;
    }

    /// Decides satisfiability of the clauses added so far.
    SolveStatus solve()
    {
        if (!ok)
            return SolveStatus.unsat;
        if (maxLearnts == 0)
        {
            const base = clauses.length / 3;
            maxLearnts = base > minLearnts ? base : minLearnts;
        }
        LBool status = LBool.Undef;
        int restartNo = 0;
        while (status == LBool.Undef)
        {
            const budget = cast(long)(100 * luby(2, restartNo));
            status = search(budget);
            if (status == LBool.Undef)
            {
                restartNo++;
                st.restarts++;
                if (learnts.length >= maxLearnts)
                {
                    reduceDB();
                    maxLearnts *= 1.1;
                }
            }
        }
        if (status == LBool.True)
        {
            modelVals = new bool[numVars];
            foreach (v; 0 .. numVars)
                modelVals[v] = litVal[2 * v] == 1;
            cancelUntil(0);
            return SolveStatus.sat;
        }
        ok = false;
        return SolveStatus.unsat;
    }

    /// The satisfying assignment found by the last `sat` result;
    /// `model[v]` is the value of zero-based variable `v`.
    const(bool)[] model() const pure nothrow @nogc @safe { return modelVals; }

    // ------------------------------------------------------------------
    private:

    int decisionLevel() const pure nothrow @nogc @safe { return cast(int) trailLim.length; }

    LBool value(Lit p) const pure nothrow @nogc @safe { return cast(LBool) litVal[p.x]; }

    void attach(Clause c) pure nothrow @safe
    {
        watches[(~c.lits[0]).x].push(Watcher(c, c.lits[1]));
        watches[(~c.lits[1]).x].push(Watcher(c, c.lits[0]));
    }

    void uncheckedEnqueue(Lit p, Clause from) pure nothrow @safe
    {
        litVal[p.x] = 1;
        litVal[(~p).x] = 0;
        level[p.var] = decisionLevel;
        reason[p.var] = from;
        trail ~= p;
    }

    /// Unit propagation; returns a conflicting clause or null.
    Clause propagate() nothrow
    {
        Clause confl = null;
        while (qhead < trail.length)
        {
            const p = trail[qhead++];
            st.propagations++;
            const falseLit = ~p;
            auto wl = &watches[p.x];
            auto ws = wl.data;
            const n = wl.len;
            size_t i = 0, j = 0;
            while (i < n)
            {
                Watcher w = ws[i++];
                if (value(w.blocker) == LBool.True)
                {
                    ws[j++] = w;
                    continue;
                }
                auto c = w.clause;
                auto lits = c.lits;
                if (lits[0] == falseLit)
                {
                    lits[0] = lits[1];
                    lits[1] = falseLit;
                }
                const first = lits[0];
                auto nw = Watcher(c, first);
                if (first != w.blocker && value(first) == LBool.True)
                {
                    ws[j++] = nw;
                    continue;
                }
                bool found = false;
                foreach (k; 2 .. lits.length)
                {
                    if (value(lits[k]) != LBool.False)
                    {
                        lits[1] = lits[k];
                        lits[k] = falseLit;
                        watches[(~lits[1]).x].push(nw);
                        found = true;
                        break;
                    }
                }
                if (found)
                    continue;
                ws[j++] = nw;
                if (value(first) == LBool.False)
                {
                    confl = c;
                    qhead = trail.length;
                    while (i < n)
                        ws[j++] = ws[i++];
                }
                else
                    uncheckedEnqueue(first, c);
            }
            wl.len = j;
            if (confl !is null)
                break;
        }
        return confl;
    }

    void newDecisionLevel() pure nothrow @safe { trailLim ~= trail.length; }

    void cancelUntil(int lvl) pure nothrow @safe
    {
        if (decisionLevel <= lvl)
            return;
        foreach_reverse (i; trailLim[lvl] .. trail.length)
        {
            const p = trail[i];
            const v = p.var;
            litVal[p.x] = 2;
            litVal[(~p).x] = 2;
            reason[v] = null;
            polarity[v] = p.sign; // remember the phase we are leaving
            order.insert(v);
        }
        qhead = trailLim[lvl];
        trail.length = trailLim[lvl];
        trailLim.length = lvl;
    }

    void claBump(Clause c) pure nothrow @safe
    {
        c.activity += claInc;
        if (c.activity > 1e20)
        {
            foreach (l; learnts)
                l.activity *= 1e-20;
            claInc *= 1e-20;
        }
    }

    /// First-UIP conflict analysis. Fills `outLearnt` (asserting literal
    /// first) and returns the backjump level.
    int analyze(Clause confl, ref Lit[] outLearnt) pure nothrow @safe
    {
        outLearnt.length = 1;
        int pathC = 0;
        Lit p = litUndef;
        size_t index = trail.length;
        do
        {
            if (confl.learnt)
                claBump(confl);
            foreach (q; confl.lits[(p.isUndef ? 0 : 1) .. $])
            {
                const v = q.var;
                if (!seen[v] && level[v] > 0)
                {
                    order.bump(v);
                    seen[v] = 1;
                    if (level[v] >= decisionLevel)
                        pathC++;
                    else
                        outLearnt ~= q;
                }
            }
            while (!seen[trail[--index].var]) {}
            p = trail[index];
            confl = reason[p.var];
            seen[p.var] = 0;
            pathC--;
        }
        while (pathC > 0);
        outLearnt[0] = ~p;

        // Local minimisation: drop a literal whose reason is entirely made
        // of literals already in the clause (or fixed at the root).
        const toClear = outLearnt.dup;
        size_t j = 1;
        foreach (i; 1 .. outLearnt.length)
        {
            const r = reason[outLearnt[i].var];
            bool keep = r is null;
            if (!keep)
            {
                foreach (q; r.lits[1 .. $])
                {
                    if (!seen[q.var] && level[q.var] > 0)
                    {
                        keep = true;
                        break;
                    }
                }
            }
            if (keep)
                outLearnt[j++] = outLearnt[i];
        }
        outLearnt.length = j;
        foreach (l; toClear)
            seen[l.var] = 0;

        int bt = 0;
        if (outLearnt.length > 1)
        {
            size_t maxI = 1;
            foreach (i; 2 .. outLearnt.length)
                if (level[outLearnt[i].var] > level[outLearnt[maxI].var])
                    maxI = i;
            swap(outLearnt[1], outLearnt[maxI]);
            bt = level[outLearnt[1].var];
        }
        return bt;
    }

    LBool search(long nofConflicts)
    {
        long conflictC = 0;
        Lit[] learnt;
        for (;;)
        {
            auto confl = propagate();
            if (confl !is null)
            {
                st.conflicts++;
                conflictC++;
                if (decisionLevel == 0)
                    return LBool.False;
                const bt = analyze(confl, learnt);
                cancelUntil(bt);
                if (learnt.length == 1)
                    uncheckedEnqueue(learnt[0], null);
                else
                {
                    auto c = new Clause(learnt.dup, true);
                    learnts ~= c;
                    attach(c);
                    claBump(c);
                    uncheckedEnqueue(learnt[0], c);
                }
                order.decay();
                claInc /= 0.999;
            }
            else
            {
                if (conflictC >= nofConflicts)
                {
                    cancelUntil(0);
                    return LBool.Undef;
                }
                const next = pickBranchLit();
                if (next.isUndef)
                    return LBool.True;
                st.decisions++;
                newDecisionLevel();
                uncheckedEnqueue(next, null);
            }
        }
    }

    Lit pickBranchLit() pure nothrow @safe
    {
        while (!order.empty)
        {
            const v = order.removeMax();
            if (litVal[2 * v] == 2)
                return Lit.make(v, polarity[v]);
        }
        return litUndef;
    }

    bool locked(Clause c) const pure nothrow @safe
    {
        const l = c.lits[0];
        return value(l) == LBool.True && reason[l.var] is c;
    }

    /// Deletes the lower-activity half of the learnt clauses (keeping binary
    /// and reason clauses) and purges their watchers.
    void reduceDB()
    {
        learnts.sort!((a, b) => a.activity < b.activity);
        const half = learnts.length / 2;
        size_t j = 0;
        foreach (i, c; learnts)
        {
            if (i < half && c.lits.length > 2 && !locked(c))
            {
                c.deleted = true;
                st.learntsDeleted++;
            }
            else
                learnts[j++] = c;
        }
        learnts.length = j;
        foreach (ref wl; watches)
        {
            size_t k = 0;
            foreach (i; 0 .. wl.len)
                if (!wl.data[i].clause.deleted)
                    wl.data[k++] = wl.data[i];
            foreach (i; k .. wl.len)
                wl.data[i] = Watcher.init; // release references for the GC
            wl.len = k;
        }
    }
}

// ----------------------------------------------------------------------
// Tests

version (unittest)
{
    private bool bruteForce(int n, const int[][] cls)
    {
        foreach (m; 0 .. 1 << n)
        {
            bool all = true;
            foreach (c; cls)
            {
                bool any = false;
                foreach (l; c)
                {
                    const v = (l < 0 ? -l : l) - 1;
                    if (((m >> v) & 1) == (l > 0 ? 1 : 0))
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

    private int[][] randomCnf(ref Random rng, int n, int m, int k)
    {
        int[][] r;
        foreach (_; 0 .. m)
        {
            int[] c;
            foreach (__;  0 .. k)
            {
                const v = uniform(1, n + 1, rng);
                c ~= uniform(0, 2, rng) ? v : -v;
            }
            r ~= c;
        }
        return r;
    }

    import std.random : Random, uniform;
    import sat.model : satisfies;
    import sat.dimacs : Cnf;

    private int[][] pigeonhole(int holes)
    {
        const pigeons = holes + 1;
        int var(int p, int h) { return p * holes + h + 1; }
        int[][] r;
        foreach (p; 0 .. pigeons)
        {
            int[] c;
            foreach (h; 0 .. holes)
                c ~= var(p, h);
            r ~= c;
        }
        foreach (h; 0 .. holes)
            foreach (p; 0 .. pigeons)
                foreach (q; p + 1 .. pigeons)
                    r ~= [-var(p, h), -var(q, h)];
        return r;
    }
}

unittest
{
    // Luby sequence 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8
    int[] got;
    foreach (i; 0 .. 15)
        got ~= cast(int) luby(2, i);
    assert(got == [1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8]);
}

unittest
{
    // trivial cases
    auto s = new Solver;
    assert(s.solve() == SolveStatus.sat);

    s = new Solver(3);
    assert(s.addClause([1, -1]));          // tautology
    assert(s.addClause([2, 2, 3]));        // duplicates
    assert(s.solve() == SolveStatus.sat);
    assert(s.model.length == 3);

    s = new Solver(1);
    assert(!s.addClause(cast(int[])[]));   // empty clause
    assert(s.solve() == SolveStatus.unsat);

    s = new Solver(1);
    assert(s.addClause([1]));
    assert(!s.addClause([-1]));
    assert(s.solve() == SolveStatus.unsat);
}

unittest
{
    // units propagate and the model respects them
    auto s = new Solver;
    s.addClause([1]);
    s.addClause([-1, 2]);
    s.addClause([-2, -3]);
    assert(s.solve() == SolveStatus.sat);
    assert(s.model[0] && s.model[1] && !s.model[2]);
}

unittest
{
    // random small formulas agree with brute force; models are valid
    auto rng = Random(12345);
    foreach (iter; 0 .. 400)
    {
        const n = uniform(1, 11, rng);
        const m = uniform(1, 50, rng);
        const k = uniform(1, 4, rng);
        auto cls = randomCnf(rng, n, m, k);
        const cnf = Cnf(n, cls);
        auto s = new Solver(n);
        s.minLearnts = 4; // exercise clause deletion too
        bool ok = true;
        foreach (c; cls)
            ok = s.addClause(c) && ok;
        const res = ok ? s.solve() : SolveStatus.unsat;
        assert((res == SolveStatus.sat) == bruteForce(n, cls));
        if (res == SolveStatus.sat)
            assert(satisfies(cnf, s.model));
    }
}

unittest
{
    // pigeonhole formulas are unsatisfiable
    foreach (h; 2 .. 8)
    {
        auto s = new Solver;
        foreach (c; pigeonhole(h))
            s.addClause(c);
        assert(s.solve() == SolveStatus.unsat);
        assert(s.stats.conflicts > 0);
    }
}

unittest
{
    // random 3-SAT at the phase transition, with aggressive deletion
    auto rng = Random(7);
    ulong deleted;
    scope (exit) assert(deleted > 0);
    foreach (iter; 0 .. 12)
    {
        const n = 120;
        auto cls = randomCnf(rng, n, 511, 3);
        auto s = new Solver(n);
        s.minLearnts = 20;
        foreach (c; cls)
            s.addClause(c);
        const res = s.solve();
        if (res == SolveStatus.sat)
            assert(satisfies(Cnf(n, cls), s.model));
        deleted += s.stats.learntsDeleted;
    }
}

unittest
{
    // a very long clause plus unit clauses forcing the last literal
    int[] big;
    foreach (i; 1 .. 1001)
        big ~= i;
    auto s = new Solver(1000);
    s.addClause(big);
    foreach (i; 1 .. 1000)
        s.addClause([-i]);
    assert(s.solve() == SolveStatus.sat);
    assert(s.model[999]);
}
