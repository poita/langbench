/**
 * The CDCL solver.
 *
 * A MiniSat-style conflict-driven clause-learning solver with
 * $(UL
 *   $(LI two watched literals per clause,)
 *   $(LI first-UIP conflict analysis with local clause minimisation,)
 *   $(LI VSIDS branching on an indexed binary heap with phase saving,)
 *   $(LI Luby restarts (100 conflicts times the Luby sequence), and)
 *   $(LI activity-based reduction of the learnt-clause database between restarts.)
 * )
 *
 * Every tie-break and ordering (watch lists, heap, stable-sorted reduction)
 * is deterministic, so a given formula always yields the same search.
 */
module sat.solver;

import std.algorithm.mutation : swap, SwapStrategy;
import std.algorithm.sorting : sort;
import std.exception : enforce;

import sat.dimacs : Cnf;
import sat.heap : VarHeap;
import sat.luby : luby2;
import sat.types;

/// Outcome of $(LREF solve).
struct SolveResult
{
    /// True if the formula is satisfiable.
    bool satisfiable;
    /// When satisfiable: `model[i]` is the value of DIMACS variable `i + 1`.
    bool[] model;
}

/// Counters describing the work done by a $(LREF Solver).
struct Stats
{
    ulong conflicts;
    ulong decisions;
    ulong propagations;
    ulong restarts;
    ulong learnts;       /// clauses learnt (including units)
    ulong reductions;    /// learnt-database reductions
}

/**
 * Solve a parsed formula.
 *
 * Clauses are added in input order. The returned model (when satisfiable)
 * assigns every variable `1 .. cnf.numVars`.
 */
SolveResult solve(const ref Cnf cnf)
{
    auto solver = new Solver(cnf.numVars);
    foreach (i; 0 .. cnf.numClauses)
    {
        if (!solver.addClause(cnf.clause(i)))
            break;
    }
    SolveResult r;
    r.satisfiable = solver.solve();
    if (r.satisfiable)
        r.model = solver.model.dup;
    return r;
}

/**
 * Incremental-style CDCL solver: create it with the number of variables, add
 * clauses with $(LREF addClause), then call $(LREF solve) once.
 *
 * ---
 * auto s = new Solver(3);
 * s.addClause([1, -2]);
 * s.addClause([2, 3]);
 * if (s.solve())
 *     writeln(s.model);   // truth value of variables 1..3
 * ---
 */
final class Solver
{
    private
    {
        // Truth values per literal.
        enum ubyte vFalse = 0, vTrue = 1, vUndef = 2;

        struct Clause
        {
            int[] lits;
            double activity = 0;
            bool learnt;
        }

        // A watch list: clause references with an explicit length so that
        // propagation can compact it in place.
        struct WatchList
        {
            int[] data;
            int len;

            void push(int cr) pure nothrow
            {
                if (len == data.length)
                    data.length = len < 4 ? 4 : 2 * len;
                data[len++] = cr;
            }
        }

        int nVars;
        bool consistent = true;      // false once the formula is known UNSAT
        bool solved;
        bool[] modelValues;

        ubyte[] assigns;             // per literal
        int[] level;                 // per variable
        int[] reason;                // per variable: ClauseRef or noClause
        bool[] phase;                // saved phase per variable
        double[] activity;           // VSIDS activity per variable
        ubyte[] seen;                // per variable, scratch for analysis

        int[] trail;
        int trailLen;
        int[] trailLim;              // trail size at the start of each decision level
        int numLevels;
        int qhead;

        WatchList[] watches;         // per literal
        Clause[] clauses;
        int[] freeSlots;
        int[] inputRefs;             // stored input clauses, in insertion order
        int[] learntRefs;            // live learnt clauses

        VarHeap heap;
        double varInc = 1.0;
        double claInc = 1.0;
        long maxLearnts;

        int[] learntBuf;             // scratch: clause being learnt
        int learntLen;
        int[] clearBuf;              // scratch: variables whose `seen` must be reset
        int clearLen;

        Stats statistics;
    }

    /// A solver over variables `1 .. numVars` with no clauses.
    this(int numVars)
    {
        enforce(numVars >= 0, "negative variable count");
        nVars = numVars;
        assigns = new ubyte[2 * numVars];
        assigns[] = vUndef;
        level = new int[numVars];
        reason = new int[numVars];
        reason[] = noClause;
        phase = new bool[numVars];
        activity = new double[numVars];
        activity[] = 0.0;
        seen = new ubyte[numVars];
        trail = new int[numVars];
        trailLim = new int[numVars + 1];
        watches = new WatchList[2 * numVars];
        learntBuf = new int[numVars + 1];
        clearBuf = new int[numVars + 1];
        heap = VarHeap(activity);
        foreach (v; 0 .. numVars)
            heap.insert(v);
    }

    /// Work counters so far.
    ref const(Stats) stats() const { return statistics; }

    /// Number of variables.
    int numVars() const { return nVars; }

    /// False once the clauses added so far are known to be contradictory.
    bool isConsistent() const { return consistent; }

    /// After a successful $(LREF solve): value of DIMACS variable `i + 1` at index `i`.
    const(bool)[] model() const
    {
        enforce(solved, "no model available");
        return modelValues;
    }

    /**
     * Add a clause given as non-zero DIMACS literals.
     *
     * Duplicate literals are merged, tautologies and clauses already satisfied
     * at the root are dropped, root-false literals are removed. An empty
     * result makes the formula unsatisfiable; a unit is assigned and
     * propagated immediately.
     *
     * Returns: false if the formula is now known to be unsatisfiable (further
     * clauses are ignored).
     */
    bool addClause(scope const(int)[] dimacsLits)
    {
        if (!consistent)
            return false;
        assert(numLevels == 0);

        int[] ls = new int[dimacsLits.length];
        foreach (i, d; dimacsLits)
        {
            enforce(d != 0 && (d > 0 ? d : -d) <= nVars, "literal out of range");
            ls[i] = fromDimacs(d);
        }
        ls.sort();

        // Drop duplicates, detect tautologies, simplify against the root assignment.
        size_t j = 0;
        foreach (i; 0 .. ls.length)
        {
            immutable l = ls[i];
            if (j > 0 && ls[j - 1] == l)
                continue;
            if (j > 0 && ls[j - 1] == neg(l))
                return true;                     // tautology
            if (assigns[l] == vTrue)
                return true;                     // satisfied at root
            if (assigns[l] == vFalse)
                continue;                        // false at root
            ls[j++] = l;
        }
        ls = ls[0 .. j];
        // A tautology may be completed by a later literal that was skipped as
        // root-false; neither case changes satisfiability, so no re-check.

        if (ls.length == 0)
        {
            consistent = false;
            return false;
        }
        if (ls.length == 1)
        {
            enqueue(ls[0], noClause);
            if (propagate() != noClause)
                consistent = false;
            return consistent;
        }
        immutable cr = newClause(ls, false);
        inputRefs ~= cr;
        attach(cr);
        return true;
    }

    /**
     * Decide satisfiability of the clauses added so far.
     *
     * Returns: true if satisfiable (then $(LREF model) is available).
     */
    bool solve()
    {
        if (!consistent)
            return false;
        maxLearnts = inputRefs.length / 3;
        if (maxLearnts < 2000)
            maxLearnts = 2000;

        bool answer;
        for (long i = 0;; ++i)
        {
            immutable budget = 100 * luby2(i);
            immutable r = search(budget);
            if (r != 2)
            {
                answer = r == 1;
                break;
            }
            ++statistics.restarts;
            if (cast(long) learntRefs.length >= maxLearnts)
            {
                reduceDB();
                maxLearnts = cast(long)(cast(double) maxLearnts * 1.1);
            }
        }
        if (answer)
        {
            modelValues = new bool[nVars];
            foreach (v; 0 .. nVars)
                modelValues[v] = assigns[2 * v] == vTrue;
            solved = true;
        }
        else
        {
            consistent = false;
        }
        return answer;
    }

private:

    // ---- assignment ------------------------------------------------------

    void enqueue(Lit l, ClauseRef from)
    {
        assigns[l] = vTrue;
        assigns[l ^ 1] = vFalse;
        immutable v = l >> 1;
        level[v] = numLevels;
        reason[v] = from;
        trail[trailLen++] = l;
    }

    void cancelUntil(int lvl)
    {
        if (numLevels <= lvl)
            return;
        immutable stop = trailLim[lvl];
        for (int i = trailLen - 1; i >= stop; --i)
        {
            immutable l = trail[i];
            immutable v = l >> 1;
            assigns[l] = vUndef;
            assigns[l ^ 1] = vUndef;
            reason[v] = noClause;
            phase[v] = (l & 1) == 0;
            heap.insert(v);
        }
        trailLen = stop;
        numLevels = lvl;
        qhead = stop;
    }

    // ---- clause storage ----------------------------------------------------

    ClauseRef newClause(int[] lits, bool learnt)
    {
        ClauseRef cr;
        if (freeSlots.length > 0)
        {
            cr = freeSlots[$ - 1];
            freeSlots = freeSlots[0 .. $ - 1];
            freeSlots.assumeSafeAppend();
        }
        else
        {
            cr = cast(ClauseRef) clauses.length;
            clauses ~= Clause.init;
        }
        clauses[cr] = Clause(lits, 0.0, learnt);
        return cr;
    }

    void attach(ClauseRef cr)
    {
        auto c = clauses[cr].lits;
        watches[c[0]].push(cr);
        watches[c[1]].push(cr);
    }

    // ---- propagation -------------------------------------------------------

    /// Unit propagation; returns the conflicting clause or noClause.
    ClauseRef propagate()
    {
        while (qhead < trailLen)
        {
            immutable p = trail[qhead++];
            immutable np = p ^ 1;        // literal that just became false
            ++statistics.propagations;
            auto ws = &watches[np];
            int i = 0, j = 0;
            immutable n = ws.len;
            int[] data = ws.data;
            while (i < n)
            {
                immutable cr = data[i++];
                int[] c = clauses[cr].lits;
                if (c[0] == np)
                {
                    c[0] = c[1];
                    c[1] = np;
                }
                if (assigns[c[0]] == vTrue)
                {
                    data[j++] = cr;
                    continue;
                }
                bool moved = false;
                foreach (k; 2 .. c.length)
                {
                    if (assigns[c[k]] != vFalse)
                    {
                        immutable nl = c[k];
                        c[1] = nl;
                        c[k] = np;
                        watches[nl].push(cr);
                        moved = true;
                        break;
                    }
                }
                if (moved)
                    continue;
                data[j++] = cr;
                if (assigns[c[0]] == vFalse)
                {
                    while (i < n)
                        data[j++] = data[i++];
                    ws.len = j;
                    qhead = trailLen;
                    return cr;
                }
                enqueue(c[0], cr);
            }
            ws.len = j;
        }
        return noClause;
    }

    // ---- activities --------------------------------------------------------

    void bumpVar(int v)
    {
        activity[v] += varInc;
        if (activity[v] > 1e100)
        {
            foreach (ref a; activity)
                a *= 1e-100;
            varInc *= 1e-100;
        }
        heap.increased(v);
    }

    void bumpClause(ClauseRef cr)
    {
        clauses[cr].activity += claInc;
        if (clauses[cr].activity > 1e20)
        {
            foreach (r; learntRefs)
                clauses[r].activity *= 1e-20;
            claInc *= 1e-20;
        }
    }

    // ---- conflict analysis ---------------------------------------------------

    /// First-UIP analysis of `confl`. Leaves the learnt clause in
    /// learntBuf[0 .. learntLen] with the asserting literal first and, for
    /// non-unit clauses, a literal of the backjump level second.
    /// Returns the backjump level.
    int analyze(ClauseRef confl)
    {
        int pathC = 0;
        Lit p = -1;
        int idx = trailLen - 1;
        learntLen = 1;

        do
        {
            auto c = &clauses[confl];
            if (c.learnt)
                bumpClause(confl);
            foreach (q; c.lits)
            {
                if (q == p)
                    continue;
                immutable v = q >> 1;
                if (!seen[v] && level[v] > 0)
                {
                    seen[v] = 1;
                    bumpVar(v);
                    if (level[v] >= numLevels)
                        ++pathC;
                    else
                        learntBuf[learntLen++] = q;
                }
            }
            do
            {
                p = trail[idx--];
            }
            while (!seen[p >> 1]);
            confl = reason[p >> 1];
            seen[p >> 1] = 0;
            --pathC;
        }
        while (pathC > 0);
        learntBuf[0] = p ^ 1;

        // Local minimisation (one level, not recursive). `seen` keeps marking
        // every literal of the unminimised clause until the end.
        clearLen = 0;
        foreach (i; 1 .. learntLen)
            clearBuf[clearLen++] = learntBuf[i] >> 1;
        int j = 1;
        foreach (i; 1 .. learntLen)
        {
            immutable q = learntBuf[i];
            immutable r = reason[q >> 1];
            bool keep = r == noClause;
            if (!keep)
            {
                foreach (l; clauses[r].lits)
                {
                    if (l == (q ^ 1))
                        continue;
                    immutable v = l >> 1;
                    if (!seen[v] && level[v] > 0)
                    {
                        keep = true;
                        break;
                    }
                }
            }
            if (keep)
                learntBuf[j++] = q;
        }
        learntLen = j;
        foreach (i; 0 .. clearLen)
            seen[clearBuf[i]] = 0;

        if (learntLen == 1)
            return 0;
        int maxI = 1;
        foreach (i; 2 .. learntLen)
            if (level[learntBuf[i] >> 1] > level[learntBuf[maxI] >> 1])
                maxI = i;
        swap(learntBuf[1], learntBuf[maxI]);
        return level[learntBuf[1] >> 1];
    }

    // ---- search ------------------------------------------------------------------

    /// Returns 1 (SAT), 0 (UNSAT) or 2 (restart).
    int search(long budget)
    {
        long conflictC = 0;
        while (true)
        {
            immutable confl = propagate();
            if (confl != noClause)
            {
                ++conflictC;
                ++statistics.conflicts;
                if (numLevels == 0)
                    return 0;
                immutable bt = analyze(confl);
                cancelUntil(bt);
                ++statistics.learnts;
                if (learntLen == 1)
                {
                    enqueue(learntBuf[0], noClause);
                }
                else
                {
                    immutable cr = newClause(learntBuf[0 .. learntLen].dup, true);
                    clauses[cr].activity = claInc;
                    learntRefs ~= cr;
                    attach(cr);
                    enqueue(learntBuf[0], cr);
                }
                varInc /= 0.95;
                claInc /= 0.999;
            }
            else
            {
                if (conflictC >= budget)
                {
                    cancelUntil(0);
                    return 2;
                }
                // pick a branching variable
                int next = -1;
                while (!heap.empty)
                {
                    immutable v = heap.removeMax();
                    if (assigns[2 * v] == vUndef)
                    {
                        next = v;
                        break;
                    }
                }
                if (next < 0)
                    return 1;
                ++statistics.decisions;
                trailLim[numLevels++] = trailLen;
                enqueue(mkLit(next, phase[next]), noClause);
            }
        }
    }

    // ---- learnt database reduction ---------------------------------------------------

    /// Delete the less active half of the learnt clauses (keeping binary ones)
    /// and rebuild every watch list. Only called at decision level 0.
    void reduceDB()
    {
        ++statistics.reductions;
        auto refs = learntRefs;
        refs.sort!((a, b) => clauses[a].activity < clauses[b].activity, SwapStrategy.stable)();
        immutable half = refs.length / 2;
        size_t kept = 0;
        foreach (i, cr; refs)
        {
            if (i < half && clauses[cr].lits.length > 2)
            {
                clauses[cr] = Clause.init;
                freeSlots ~= cr;
            }
            else
            {
                refs[kept++] = cr;
            }
        }
        learntRefs = refs[0 .. kept];

        foreach (ref w; watches)
            w.len = 0;
        foreach (cr; inputRefs)
            attach(cr);
        foreach (cr; learntRefs)
            attach(cr);
    }
}
