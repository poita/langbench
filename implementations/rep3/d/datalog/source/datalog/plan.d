/**
 * Compilation of rules into join plans.
 *
 * A plan is a list of steps, one per positive body atom, executed as a
 * nested-loop join. Each step either scans a range of tuples, looks up a hash
 * index on its bound arguments, or (when every argument is bound) probes the
 * relation's hash set. Negated atoms and comparisons are attached as filters
 * right after the earliest step at which all their variables are bound.
 */
module datalog.plan;

import datalog.ast;
import datalog.relation;

/// What a step does with one argument of its atom.
enum ArgKind : ubyte
{
    constant, /// must equal the constant `value`
    bound,    /// must equal the variable slot `value`, bound by an earlier step
    bind,     /// first occurrence of the variable: store into slot `value`
    check,    /// repeated variable within the atom: must equal slot `value`
}

/// A compiled argument.
struct Arg
{
    ArgKind kind;
    uint value;
}

/// How a step enumerates candidate tuples.
enum StepKind : ubyte
{
    scan,   /// range scan (all of `[0, hi)`, or the delta range)
    lookup, /// hash-index lookup on the bound arguments
    probe,  /// all arguments bound: membership test
}

/// A filter run once its variables are bound.
struct Filter
{
    bool isNegation;
    Relation relation;   /// for negations
    Arg[] args;          /// for negations (constant / bound only)
    CmpOp op;            /// for comparisons
    Arg lhs, rhs;        /// for comparisons (constant / bound only)
}

/// One join step.
struct Step
{
    StepKind kind;
    bool isDelta;       /// scans only the previous round's new tuples
    uint predicate;
    Relation relation;
    HashIndex index;    /// for `lookup`
    Arg[] args;
    uint[] keyColumns;  /// for `lookup`: columns forming the key, ascending
    Filter[] filters;   /// run after this step has bound its variables
}

/// A compiled rule variant.
struct Plan
{
    uint headPredicate;
    Relation headRelation;
    Arg[] headArgs;     /// constant / bound only
    uint numVars;
    Filter[] pre;       /// filters that depend on no variable
    Step[] steps;
    /// Indexes used by the steps; bring them up to date before running.
    HashIndex[] indexes;
}

private bool isVarFree(Term t) { return !t.isVar; }

/**
 * Compiles `rule` into a plan.
 *
 * Params:
 *   rule      = a safe rule with a non-empty body
 *   relations = the relation of every predicate, by predicate id
 *   deltaAtom = index into `rule.body` of the positive atom to scan as the
 *               delta (it is joined first), or -1 for the full plan
 */
Plan compilePlan(const ref Rule rule, Relation[] relations, int deltaAtom)
{
    Plan plan;
    plan.headPredicate = rule.head.predicate;
    plan.headRelation = relations[rule.head.predicate];
    plan.numVars = rule.numVars;

    auto bound = new bool[rule.numVars];
    Arg constOrBound(Term t)
    {
        return t.isVar ? Arg(ArgKind.bound, t.id) : Arg(ArgKind.constant, t.id);
    }
    foreach (t; rule.head.args)
        plan.headArgs ~= constOrBound(t);

    // Filters (negations / comparisons) not yet placed.
    size_t[] pendingFilters;
    bool[] positiveDone = new bool[rule.body.length];
    size_t remaining;
    foreach (i, ref l; rule.body)
    {
        if (l.kind == LiteralKind.positive) remaining++;
        else pendingFilters ~= i;
    }

    bool filterReady(ref const Literal l)
    {
        bool ok(Term t) { return !t.isVar || bound[t.id]; }
        if (l.kind == LiteralKind.comparison)
            return ok(l.lhs) && ok(l.rhs);
        foreach (t; l.atom.args)
            if (!ok(t)) return false;
        return true;
    }

    Filter makeFilter(ref const Literal l)
    {
        Filter f;
        if (l.kind == LiteralKind.comparison)
        {
            f.op = l.op;
            f.lhs = constOrBound(l.lhs);
            f.rhs = constOrBound(l.rhs);
        }
        else
        {
            f.isNegation = true;
            f.relation = relations[l.atom.predicate];
            foreach (t; l.atom.args)
                f.args ~= constOrBound(t);
        }
        return f;
    }

    // Moves every pending filter that is now ready into `dest`.
    void placeFilters(ref Filter[] dest)
    {
        size_t[] still;
        foreach (i; pendingFilters)
        {
            if (filterReady(rule.body[i]))
                dest ~= makeFilter(rule.body[i]);
            else
                still ~= i;
        }
        pendingFilters = still;
    }

    placeFilters(plan.pre);

    size_t pickNext()
    {
        size_t best = size_t.max;
        int bestScore = -1;
        foreach (i, ref l; rule.body)
        {
            if (l.kind != LiteralKind.positive || positiveDone[i]) continue;
            int score;
            foreach (t; l.atom.args)
                if (!t.isVar || bound[t.id]) score++;
            if (score > bestScore)
            {
                bestScore = score;
                best = i;
            }
        }
        return best;
    }

    bool first = true;
    while (remaining > 0)
    {
        size_t bi = (first && deltaAtom >= 0) ? cast(size_t) deltaAtom : pickNext();
        const isDelta = first && deltaAtom >= 0;
        first = false;
        positiveDone[bi] = true;
        remaining--;

        const atom = rule.body[bi].atom;
        Step st;
        st.predicate = atom.predicate;
        st.relation = relations[atom.predicate];
        st.isDelta = isDelta;
        bool[] seen = new bool[rule.numVars];
        uint keyMask;
        bool anyBind;
        foreach (j, t; atom.args)
        {
            if (!t.isVar)
            {
                st.args ~= Arg(ArgKind.constant, t.id);
                keyMask |= 1u << j;
            }
            else if (bound[t.id])
            {
                st.args ~= Arg(ArgKind.bound, t.id);
                keyMask |= 1u << j;
            }
            else if (seen[t.id])
                st.args ~= Arg(ArgKind.check, t.id);
            else
            {
                seen[t.id] = true;
                anyBind = true;
                st.args ~= Arg(ArgKind.bind, t.id);
            }
        }
        foreach (t; atom.args)
            if (t.isVar) bound[t.id] = true;

        if (isDelta)
            st.kind = StepKind.scan;
        else if (!anyBind)
            st.kind = StepKind.probe;
        else if (keyMask != 0)
        {
            st.kind = StepKind.lookup;
            st.index = st.relation.indexOn(keyMask);
            st.keyColumns = st.index.columns.dup;
            plan.indexes ~= st.index;
        }
        else
            st.kind = StepKind.scan;

        placeFilters(st.filters);
        plan.steps ~= st;
    }
    return plan;
}
