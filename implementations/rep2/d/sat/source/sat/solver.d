/**
 * A MiniSat-style conflict-driven clause-learning (CDCL) SAT solver.
 *
 * Features: two watched literals, first-UIP learning with local
 * minimisation, VSIDS branching on an indexed heap, phase saving, Luby
 * restarts and periodic learnt-clause database reduction.
 *
 * The search is fully deterministic: the same clauses added in the same order
 * always yield the same model.
 *
 * Example:
 * ---
 * auto s = new Solver(3);
 * s.addClause([1, -2]);
 * s.addClause([2, 3]);
 * if (s.solve() == SolveResult.sat)
 *     writeln(s.modelValue(3));
 * ---
 */
module sat.solver;

import std.algorithm.mutation : SwapStrategy;
import std.algorithm.sorting : sort;
import std.exception : enforce;

import sat.heap : VarHeap;
import sat.types;

/// Outcome of $(LREF Solver.solve).
enum SolveResult
{
    /// A satisfying assignment exists; read it with `model`.
    sat,
    /// The formula has no satisfying assignment.
    unsat,
}

/**
 * The i-th (0-based) element of the Luby sequence scaled by 2:
 * 1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8, ...
 */
long luby(long i) pure nothrow @nogc @safe
{
    long size = 1;
    int seq = 0;
    while (size < i + 1)
    {
        ++seq;
        size = 2 * size + 1;
    }
    while (size - 1 != i)
    {
        size = (size - 1) >> 1;
        --seq;
        i = i % size;
    }
    return 1L << seq;
}

/// A CDCL SAT solver over a fixed number of variables.
final class Solver
{
    private enum ubyte vUndef = 0, vTrue = 1, vFalse = 2;

    private static struct Clause
    {
        Lit[] lits;
        double activity = 0;
        bool learnt;
    }

    private
    {
        int nVars;
        bool ok = true;

        Clause[] clauses;       // storage, indexed by clause reference
        int[] freeRefs;         // recycled storage slots
        int[] inputRefs;        // stored (non-unit) input clauses, in input order
        int[] learntRefs;       // live learnt clauses

        int[][] watchList;      // literal -> clause refs (storage)
        int[] watchLen;         // literal -> used length of watchList

        ubyte[] value;          // per literal
        int[] level;            // per variable
        int[] reason;           // per variable, -1 if none
        bool[] phase;           // saved phase per variable (true = positive)
        double[] activity;      // per variable
        ubyte[] seen;           // per variable scratch

        Lit[] trail;            // fixed capacity nVars
        size_t trailLen;
        int[] trailLim;
        size_t qhead;

        VarHeap order;
        double varInc = 1.0;
        double claInc = 1.0;
        long maxLearnts;

        Lit[] learntBuf;
        Lit[] toClear;

        long numConflicts;
        bool[] modelBuf;
    }

    /// Creates a solver for variables `1 .. numVars`.
    this(int numVars)
    {
        enforce(numVars >= 0, "negative variable count");
        nVars = numVars;
        const nl = 2 * numVars;
        watchList = new int[][nl];
        watchLen = new int[nl];
        value = new ubyte[nl];
        level = new int[numVars];
        reason = new int[numVars];
        reason[] = -1;
        phase = new bool[numVars];
        activity = new double[numVars];
        activity[] = 0.0; // D defaults doubles to NaN
        seen = new ubyte[numVars];
        trail = new Lit[numVars];
        order = VarHeap(numVars, activity);
        foreach (v; 0 .. numVars)
            order.insert(v);
        modelBuf = new bool[numVars];
    }

    /// Number of variables.
    @property int numVars() const pure nothrow @nogc @safe { return nVars; }

    /// Number of conflicts encountered so far.
    @property long conflicts() const pure nothrow @nogc @safe { return numConflicts; }

    /**
     * Adds a clause given as DIMACS literals (non-zero, `|l| <= numVars`).
     *
     * Returns: `false` if the formula is already known to be unsatisfiable.
     * Throws: Exception for literals out of range. Must be called before
     * `solve`.
     */
    bool addClause(const(int)[] dimacsLits)
    {
        if (!ok)
            return false;
        assert(decisionLevel == 0);
        Lit[] ls = new Lit[dimacsLits.length];
        foreach (i, d; dimacsLits)
        {
            enforce(d != 0 && (d < 0 ? -cast(long) d : d) <= nVars, "literal out of range");
            ls[i] = fromDimacs(d);
        }
        ls.sort();

        // Dedupe, detect tautologies, simplify against the root assignment.
        size_t j = 0;
        Lit prev = litUndef;
        foreach (l; ls)
        {
            if (l == prev)
                continue;
            if (prev != litUndef && l == (prev ^ 1))
                return true; // tautology (adjacent after sorting)
            prev = l;
            ls[j++] = l;
        }
        ls.length = j;
        j = 0;
        foreach (l; ls)
        {
            if (value[l] == vTrue)
                return true; // satisfied at the root
            if (value[l] == vUndef)
                ls[j++] = l;
        }
        ls.length = j;

        if (ls.length == 0)
        {
            ok = false;
            return false;
        }
        if (ls.length == 1)
        {
            enqueue(ls[0], -1);
            if (propagate() >= 0)
            {
                ok = false;
                return false;
            }
            return true;
        }
        const ref_ = allocClause(ls, false);
        inputRefs ~= ref_;
        attach(ref_);
        return true;
    }

    /**
     * Searches for a satisfying assignment of the clauses added so far.
     * Call at most once.
     */
    SolveResult solve()
    {
        if (!ok)
            return SolveResult.unsat;
        const stored = cast(long) inputRefs.length / 3;
        maxLearnts = stored > 2000 ? stored : 2000;
        for (long i = 0;; ++i)
        {
            const status = search(100 * luby(i));
            if (status == 1)
            {
                foreach (v; 0 .. nVars)
                    modelBuf[v] = value[2 * v] == vTrue;
                cancelUntil(0);
                return SolveResult.sat;
            }
            if (status == 2)
            {
                ok = false;
                return SolveResult.unsat;
            }
            if (cast(long) learntRefs.length >= maxLearnts)
            {
                reduceDB();
                maxLearnts = cast(long)(cast(double) maxLearnts * 1.1);
            }
        }
    }

    /// The model found by the last successful `solve`; index i is variable i+1.
    @property const(bool)[] model() const pure nothrow @nogc @safe { return modelBuf; }

    /// Value of DIMACS variable `v` (1-based) in the model.
    bool modelValue(int v) const pure @safe
    {
        enforce(v >= 1 && v <= nVars, "variable out of range");
        return modelBuf[v - 1];
    }

    // ------------------------------------------------------------------

    private int decisionLevel() const pure nothrow @nogc @safe
    {
        return cast(int) trailLim.length;
    }

    private int allocClause(Lit[] lits, bool learnt) nothrow
    {
        int r;
        if (freeRefs.length)
        {
            r = freeRefs[$ - 1];
            freeRefs.length = freeRefs.length - 1;
            freeRefs.assumeSafeAppend();
        }
        else
        {
            r = cast(int) clauses.length;
            clauses.length = clauses.length + 1;
        }
        clauses[r] = Clause(lits, 0.0, learnt);
        return r;
    }

    private void pushWatch(Lit l, int r) nothrow
    {
        auto n = watchLen[l];
        if (n == watchList[l].length)
            watchList[l].length = n == 0 ? 4 : n * 2;
        watchList[l][n] = r;
        watchLen[l] = n + 1;
    }

    private void attach(int r) nothrow
    {
        const ls = clauses[r].lits;
        pushWatch(ls[0], r);
        pushWatch(ls[1], r);
    }

    private void enqueue(Lit l, int from) nothrow @nogc
    {
        value[l] = vTrue;
        value[l ^ 1] = vFalse;
        const v = l >> 1;
        level[v] = decisionLevel;
        reason[v] = from;
        trail[trailLen++] = l;
    }

    /// Unit propagation. Returns the conflicting clause ref or -1.
    private int propagate() nothrow
    {
        while (qhead < trailLen)
        {
            const p = trail[qhead++];
            const falseLit = p ^ 1;
            int[] ws = watchList[falseLit];
            const n = watchLen[falseLit];
            int i = 0, j = 0;
            while (i < n)
            {
                const r = ws[i++];
                Lit[] c = clauses[r].lits;
                if (c[0] == falseLit)
                {
                    c[0] = c[1];
                    c[1] = falseLit;
                }
                if (value[c[0]] == vTrue)
                {
                    ws[j++] = r;
                    continue;
                }
                bool found = false;
                foreach (k; 2 .. c.length)
                {
                    if (value[c[k]] != vFalse)
                    {
                        c[1] = c[k];
                        c[k] = falseLit;
                        pushWatch(c[1], r);
                        found = true;
                        break;
                    }
                }
                if (found)
                    continue;
                ws[j++] = r;
                if (value[c[0]] == vFalse)
                {
                    while (i < n)
                        ws[j++] = ws[i++];
                    watchLen[falseLit] = j;
                    qhead = trailLen;
                    return r;
                }
                enqueue(c[0], r);
            }
            watchLen[falseLit] = j;
        }
        return -1;
    }

    private void varBump(int v) nothrow @nogc
    {
        activity[v] += varInc;
        if (activity[v] > 1e100)
        {
            foreach (ref a; activity)
                a *= 1e-100;
            varInc *= 1e-100;
        }
        order.increased(v);
    }

    private void claBump(ref Clause c) nothrow @nogc
    {
        c.activity += claInc;
        if (c.activity > 1e20)
        {
            foreach (r; learntRefs)
                clauses[r].activity *= 1e-20;
            claInc *= 1e-20;
        }
    }

    private void cancelUntil(int lvl) nothrow
    {
        if (decisionLevel <= lvl)
            return;
        const mark = trailLim[lvl];
        for (size_t i = trailLen; i-- > cast(size_t) mark;)
        {
            const l = trail[i];
            const v = l >> 1;
            value[l] = vUndef;
            value[l ^ 1] = vUndef;
            reason[v] = -1;
            phase[v] = (l & 1) == 0;
            if (!order.contains(v))
                order.insert(v);
        }
        trailLen = mark;
        trailLim.length = lvl;
        trailLim.assumeSafeAppend();
        qhead = mark;
    }

    /// First-UIP analysis; fills `learntBuf` and returns the backjump level.
    private int analyze(int confl)
    {
        learntBuf.length = 1;
        learntBuf.assumeSafeAppend();
        int pathC = 0;
        Lit p = litUndef;
        size_t idx = trailLen;
        do
        {
            auto c = &clauses[confl];
            if (c.learnt)
                claBump(*c);
            foreach (q; c.lits)
            {
                if (q == p)
                    continue;
                const v = q >> 1;
                if (!seen[v] && level[v] > 0)
                {
                    seen[v] = 1;
                    varBump(v);
                    if (level[v] >= decisionLevel)
                        ++pathC;
                    else
                        learntBuf ~= q;
                }
            }
            do
            {
                --idx;
            }
            while (!seen[trail[idx] >> 1]);
            p = trail[idx];
            confl = reason[p >> 1];
            seen[p >> 1] = 0;
            --pathC;
        }
        while (pathC > 0);
        learntBuf[0] = p ^ 1;

        // Local (one-level) minimisation; `seen` keeps marking dropped ones.
        toClear.length = 0;
        toClear.assumeSafeAppend();
        toClear ~= learntBuf;
        size_t j = 1;
        foreach (i; 1 .. learntBuf.length)
        {
            const q = learntBuf[i];
            const r = reason[q >> 1];
            bool keep = true;
            if (r >= 0)
            {
                keep = false;
                foreach (x; clauses[r].lits)
                {
                    if (x == (q ^ 1))
                        continue;
                    const xv = x >> 1;
                    if (!seen[xv] && level[xv] > 0)
                    {
                        keep = true;
                        break;
                    }
                }
            }
            if (keep)
                learntBuf[j++] = q;
        }
        learntBuf.length = j;
        foreach (l; toClear)
            seen[l >> 1] = 0;

        if (learntBuf.length == 1)
            return 0;
        size_t best = 1;
        foreach (i; 2 .. learntBuf.length)
            if (level[learntBuf[i] >> 1] > level[learntBuf[best] >> 1])
                best = i;
        const tmp = learntBuf[1];
        learntBuf[1] = learntBuf[best];
        learntBuf[best] = tmp;
        return level[learntBuf[1] >> 1];
    }

    /// 0 = budget exhausted (restart), 1 = SAT, 2 = UNSAT.
    private int search(long budget)
    {
        long conflictC = 0;
        for (;;)
        {
            const confl = propagate();
            if (confl >= 0)
            {
                ++conflictC;
                ++numConflicts;
                if (decisionLevel == 0)
                    return 2;
                const back = analyze(confl);
                cancelUntil(back);
                if (learntBuf.length == 1)
                {
                    enqueue(learntBuf[0], -1);
                }
                else
                {
                    const r = allocClause(learntBuf.dup, true);
                    clauses[r].activity = claInc;
                    learntRefs ~= r;
                    attach(r);
                    enqueue(learntBuf[0], r);
                }
                varInc /= 0.95;
                claInc /= 0.999;
            }
            else
            {
                if (conflictC >= budget)
                {
                    cancelUntil(0);
                    return 0;
                }
                int next = -1;
                while (!order.empty)
                {
                    const v = order.removeMax();
                    if (value[2 * v] == vUndef)
                    {
                        next = v;
                        break;
                    }
                }
                if (next < 0)
                    return 1;
                trailLim ~= cast(int) trailLen;
                enqueue(mkLit(next, !phase[next]), -1);
            }
        }
    }

    /// Deletes the less active half of the learnt clauses and rebuilds watches.
    private void reduceDB()
    {
        auto cl = clauses;
        learntRefs.sort!((a, b) => cl[a].activity < cl[b].activity, SwapStrategy.stable)();
        const half = learntRefs.length / 2;
        size_t j = 0;
        foreach (i, r; learntRefs)
        {
            if (i < half && clauses[r].lits.length > 2)
            {
                clauses[r].lits = null;
                freeRefs ~= r;
            }
            else
                learntRefs[j++] = r;
        }
        learntRefs.length = j;
        learntRefs.assumeSafeAppend();

        watchLen[] = 0;
        foreach (r; inputRefs)
            attach(r);
        foreach (r; learntRefs)
            attach(r);
    }
}
