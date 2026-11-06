/**
 * The CDCL solver.
 *
 * A MiniSat-style conflict-driven clause-learning solver: two watched
 * literals, first-UIP learning with local clause minimisation, VSIDS
 * branching over an indexed heap, phase saving, Luby restarts and periodic
 * learnt-clause reduction. The search is deterministic.
 */
module sat.solver;

import std.algorithm.sorting : sort;
import std.algorithm.mutation : SwapStrategy;
import std.exception : enforce;

import sat.dimacs : Cnf;
import sat.heap : VarHeap;
import sat.luby : luby;
import sat.types;

/// Outcome of $(LREF Solver.solve).
enum Result
{
    /// A satisfying assignment exists; read it with $(LREF Solver.modelValue).
    sat,
    /// The formula is unsatisfiable.
    unsat,
}

private enum int noReason = -1;

/// Growable int vector with no bounds on hot-path access.
private struct IntVec
{
    int[] data;
    size_t len;

    void push(int x) pure nothrow @safe
    {
        if (len == data.length)
            data.length = len < 4 ? 4 : len * 2;
        data[len++] = x;
    }
}

/// Header of a stored clause; its literals live in the solver's arena.
private struct ClauseHeader
{
    uint start;
    uint len;
    double activity;
    bool learnt;
}

/**
 * A CDCL SAT solver.
 *
 * Add clauses with $(LREF addClause) (DIMACS-style integers), call
 * $(LREF solve), and on `Result.sat` read the model with
 * $(LREF modelValue).
 *
 * Example:
 * ---
 * auto s = new Solver(2);
 * s.addClause([1, 2]);
 * s.addClause([-1]);
 * assert(s.solve() == Result.sat);
 * assert(!s.modelValue(0) && s.modelValue(1)); // x1 = false, x2 = true
 * ---
 */
final class Solver
{
    private
    {
        int nVars;
        bool ok = true;

        // Clause storage.
        int[] arena;
        ClauseHeader[] headers;
        int[] inputs; // refs of stored input clauses, in storage order
        int[] learnts; // refs of live learnt clauses

        // Per-literal state.
        ubyte[] value;
        IntVec[] watches;

        // Per-variable state.
        int[] level;
        int[] reason;
        bool[] phase;
        ubyte[] seen;
        double[] activity;
        VarHeap order;

        // Trail.
        int[] trail;
        int trailLen;
        int qhead;
        int[] trailLim;
        int numLevels;

        double varInc = 1.0;
        double claInc = 1.0;
        long maxLearnts;

        // Scratch buffers.
        int[] learntBuf;
        int[] toClear;
        int[] addBuf;
    }

    /// Create a solver over variables `1 .. numVars` (DIMACS numbering).
    this(int numVars)
    {
        enforce(numVars >= 0, "negative variable count");
        nVars = numVars;
        value = new ubyte[2 * numVars];
        watches = new IntVec[2 * numVars];
        level = new int[numVars];
        reason = new int[numVars];
        reason[] = noReason;
        phase = new bool[numVars];
        seen = new ubyte[numVars];
        activity = new double[numVars];
        activity[] = 0.0; // D default-initialises doubles to NaN
        trail = new int[numVars];
        order = VarHeap(numVars, cast(const(double)[]*)&activity);
        foreach (v; 0 .. numVars)
            order.insert(v);
    }

    /// Create a solver preloaded with the clauses of `cnf`.
    static Solver fromCnf(const ref Cnf cnf)
    {
        auto s = new Solver(cnf.numVars);
        foreach (i; 0 .. cnf.length)
        {
            if (!s.addClause(cnf[i]))
                break;
        }
        return s;
    }

    /// Number of variables.
    int numVars() const pure nothrow @safe @nogc
    {
        return nVars;
    }

    /// Number of input clauses stored (units, tautologies and satisfied clauses are not stored).
    size_t numStoredClauses() const pure nothrow @safe @nogc
    {
        return inputs.length;
    }

    /// Number of learnt clauses currently kept.
    size_t numLearnts() const pure nothrow @safe @nogc
    {
        return learnts.length;
    }

    /**
     * Add a clause given as non-zero DIMACS literals (`k` or `-k`, `1 <= k <= numVars`).
     *
     * Returns: `false` once the formula is known unsatisfiable (further clauses are ignored).
     */
    bool addClause(scope const(int)[] dimacsLits)
    {
        if (!ok)
            return false;
        addBuf.length = 0;
        foreach (d; dimacsLits)
        {
            enforce(d != 0 && (d > 0 ? d : -d) <= nVars, "literal out of range");
            addBuf ~= fromDimacs(d);
        }
        addBuf.sort();

        // Remove duplicates and detect p / not-p pairs (adjacent once sorted).
        size_t n = 0;
        foreach (l; addBuf)
        {
            if (n > 0 && addBuf[n - 1] == l)
                continue;
            if (n > 0 && (addBuf[n - 1] ^ 1) == l)
                return true; // tautology
            addBuf[n++] = l;
        }
        // Simplify against the root assignment.
        size_t m = 0;
        foreach (l; addBuf[0 .. n])
        {
            if (value[l] == lTrue)
                return true;
            if (value[l] == lUndef)
                addBuf[m++] = l;
        }
        n = m;
        addBuf.length = n;
        if (n == 0)
        {
            ok = false;
            return false;
        }
        if (n == 1)
        {
            enqueue(addBuf[0], noReason);
            if (propagate() != noReason)
                ok = false;
            return ok;
        }
        int cr = newClause(addBuf, false);
        inputs ~= cr;
        attach(cr);
        return true;
    }

    /// Decide satisfiability of the clauses added so far.
    Result solve()
    {
        if (!ok)
            return Result.unsat;
        cancelUntil(0);
        long stored = cast(long) inputs.length / 3;
        maxLearnts = stored > 2000 ? stored : 2000;
        for (long i = 0;; i++)
        {
            int status = search(100 * luby(2, i));
            if (status > 0)
                return Result.sat;
            if (status < 0)
            {
                ok = false;
                return Result.unsat;
            }
            if (cast(long) learnts.length >= maxLearnts)
            {
                reduceDB();
                maxLearnts = cast(long)(cast(double) maxLearnts * 1.1);
            }
        }
    }

    /// Truth value of variable `v` (0-based) in the model found by the last `solve() == Result.sat`.
    bool modelValue(int v) const pure nothrow @safe @nogc
    in (v >= 0 && v < nVars)
    {
        return value[2 * v] == lTrue;
    }

    // ---------------------------------------------------------------- internals

    private int newClause(const(int)[] lits, bool learnt)
    {
        ClauseHeader h;
        h.start = cast(uint) arena.length;
        h.len = cast(uint) lits.length;
        h.learnt = learnt;
        h.activity = learnt ? claInc : 0.0;
        arena ~= lits;
        headers ~= h;
        return cast(int) headers.length - 1;
    }

    private void attach(int cr) @trusted
    {
        const int* c = arena.ptr + headers[cr].start;
        watches[c[0]].push(cr);
        watches[c[1]].push(cr);
    }

    private int decisionLevel() const pure nothrow @safe @nogc
    {
        return numLevels;
    }

    private void enqueue(Lit l, int from) pure nothrow @trusted @nogc
    {
        value[l] = lTrue;
        value[l ^ 1] = lFalse;
        const v = l >> 1;
        level[v] = numLevels;
        reason[v] = from;
        trail[trailLen++] = l;
    }

    /// Unit propagation. Returns the conflicting clause or `noReason`.
    private int propagate() nothrow @trusted
    {
        int confl = noReason;
        ubyte* val = value.ptr;
        const int* ar = arena.ptr;
        const ClauseHeader* hd = headers.ptr;
        while (qhead < trailLen)
        {
            const Lit p = trail[qhead++];
            const Lit fl = p ^ 1;
            IntVec* wl = &watches[fl];
            int* ws = wl.data.ptr;
            const size_t n = wl.len;
            size_t i = 0, j = 0;
            while (i < n)
            {
                const int cr = ws[i++];
                int* c = cast(int*)(ar + hd[cr].start);
                if (c[0] == fl)
                {
                    c[0] = c[1];
                    c[1] = fl;
                }
                const Lit first = c[0];
                if (val[first] == lTrue)
                {
                    ws[j++] = cr;
                    continue;
                }
                const uint len = hd[cr].len;
                bool moved = false;
                for (uint k = 2; k < len; k++)
                {
                    if (val[c[k]] != lFalse)
                    {
                        c[1] = c[k];
                        c[k] = fl;
                        watches[c[1]].push(cr);
                        moved = true;
                        break;
                    }
                }
                if (moved)
                    continue;
                ws[j++] = cr;
                if (val[first] == lFalse)
                {
                    confl = cr;
                    qhead = trailLen;
                    while (i < n)
                        ws[j++] = ws[i++];
                }
                else
                    enqueue(first, cr);
            }
            wl.len = j;
            if (confl != noReason)
                break;
        }
        return confl;
    }

    private void newDecisionLevel() pure nothrow @safe
    {
        if (trailLim.length <= numLevels)
            trailLim ~= trailLen;
        else
            trailLim[numLevels] = trailLen;
        numLevels++;
    }

    private void cancelUntil(int lvl) pure nothrow @trusted
    {
        if (numLevels <= lvl)
            return;
        const int lim = trailLim[lvl];
        for (int i = trailLen - 1; i >= lim; i--)
        {
            const Lit l = trail[i];
            const v = l >> 1;
            value[l] = lUndef;
            value[l ^ 1] = lUndef;
            reason[v] = noReason;
            phase[v] = (l & 1) == 0;
            if (!order.contains(v))
                order.insert(v);
        }
        trailLen = lim;
        numLevels = lvl;
        qhead = lim;
    }

    private void bumpVar(Var v) pure nothrow @trusted
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

    private void bumpClause(int cr) pure nothrow @trusted
    {
        ClauseHeader* h = &headers[cr];
        h.activity += claInc;
        if (h.activity > 1e20)
        {
            foreach (lr; learnts)
                headers[lr].activity *= 1e-20;
            claInc *= 1e-20;
        }
    }

    /// First-UIP analysis of `confl`; fills `learntBuf` and returns the backjump level.
    private int analyze(int confl) nothrow @trusted
    {
        learntBuf.length = 1; // slot 0 reserved for the asserting literal
        int pathC = 0;
        Lit p = -1;
        int index = trailLen - 1;
        const int cur = numLevels;
        const int* ar = arena.ptr;
        do
        {
            const ClauseHeader* h = &headers[confl];
            if (h.learnt)
                bumpClause(confl);
            const int* c = ar + h.start;
            foreach (k; 0 .. h.len)
            {
                const Lit q = c[k];
                if (q == p)
                    continue;
                const v = q >> 1;
                if (!seen[v] && level[v] > 0)
                {
                    seen[v] = 1;
                    bumpVar(v);
                    if (level[v] >= cur)
                        pathC++;
                    else
                        learntBuf ~= q;
                }
            }
            while (!seen[trail[index] >> 1])
                index--;
            p = trail[index];
            index--;
            confl = reason[p >> 1];
            seen[p >> 1] = 0;
            pathC--;
        }
        while (pathC > 0);
        learntBuf[0] = p ^ 1;

        // Local minimisation: drop q whose reason is covered by the clause.
        toClear.length = 0;
        toClear ~= learntBuf[1 .. $];
        size_t w = 1;
        foreach (i; 1 .. learntBuf.length)
        {
            const Lit q = learntBuf[i];
            const r = reason[q >> 1];
            bool keep = true;
            if (r != noReason)
            {
                const ClauseHeader* h = &headers[r];
                const int* c = ar + h.start;
                keep = false;
                foreach (k; 0 .. h.len)
                {
                    const Lit x = c[k];
                    if (x == (q ^ 1))
                        continue;
                    const v = x >> 1;
                    if (!seen[v] && level[v] > 0)
                    {
                        keep = true;
                        break;
                    }
                }
            }
            if (keep)
                learntBuf[w++] = q;
        }
        learntBuf.length = w;
        foreach (q; toClear)
            seen[q >> 1] = 0;

        if (learntBuf.length == 1)
            return 0;
        size_t maxI = 1;
        foreach (i; 2 .. learntBuf.length)
            if (level[learntBuf[i] >> 1] > level[learntBuf[maxI] >> 1])
                maxI = i;
        const Lit t = learntBuf[maxI];
        learntBuf[maxI] = learntBuf[1];
        learntBuf[1] = t;
        return level[t >> 1];
    }

    /// Returns 1 for SAT, -1 for UNSAT, 0 when the conflict budget is exhausted (restart).
    private int search(long budget)
    {
        long conflicts = 0;
        for (;;)
        {
            const confl = propagate();
            if (confl != noReason)
            {
                conflicts++;
                if (decisionLevel() == 0)
                    return -1;
                const back = analyze(confl);
                cancelUntil(back);
                if (learntBuf.length == 1)
                    enqueue(learntBuf[0], noReason);
                else
                {
                    const cr = newClause(learntBuf, true);
                    learnts ~= cr;
                    attach(cr);
                    enqueue(learntBuf[0], cr);
                }
                varInc /= 0.95;
                claInc /= 0.999;
            }
            else
            {
                if (conflicts >= budget)
                {
                    cancelUntil(0);
                    return 0;
                }
                Var next = -1;
                while (!order.empty)
                {
                    const v = order.removeMax();
                    if (value[2 * v] == lUndef)
                    {
                        next = v;
                        break;
                    }
                }
                if (next < 0)
                    return 1;
                newDecisionLevel();
                enqueue(mkLit(next, !phase[next]), noReason);
            }
        }
    }

    /// Drop the less active half of the learnt clauses, compact storage and rebuild watches.
    private void reduceDB()
    {
        // Level-0 reasons are never consulted again.
        foreach (i; 0 .. trailLen)
            reason[trail[i] >> 1] = noReason;

        const(ClauseHeader)[] hd = headers;
        auto sorted = learnts.dup;
        sorted.sort!((a, b) => hd[a].activity < hd[b].activity, SwapStrategy.stable)();
        const half = sorted.length / 2;

        int[] newArena;
        newArena.reserve(arena.length);
        ClauseHeader[] newHeaders;
        newHeaders.reserve(inputs.length + sorted.length);

        int copy(int cr)
        {
            ClauseHeader h = hd[cr];
            const s = h.start;
            h.start = cast(uint) newArena.length;
            newArena ~= arena[s .. s + h.len];
            newHeaders ~= h;
            return cast(int) newHeaders.length - 1;
        }

        foreach (ref cr; inputs)
            cr = copy(cr);
        int[] kept;
        kept.reserve(sorted.length);
        foreach (i, cr; sorted)
        {
            if (i < half && hd[cr].len > 2)
                continue;
            kept ~= copy(cr);
        }
        arena = newArena;
        headers = newHeaders;
        learnts = kept;

        foreach (ref w; watches)
            w.len = 0;
        foreach (cr; inputs)
            attach(cr);
        foreach (cr; learnts)
            attach(cr);
    }
}

/// Solve a parsed formula in one call; returns the verdict and the solver (for the model).
Result solveCnf(const ref Cnf cnf, out Solver solver)
{
    solver = Solver.fromCnf(cnf);
    return solver.solve();
}
