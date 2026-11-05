/// Compilation of rules into nested-loop join plans.
module datalog.plan;

import datalog.ast;
import datalog.relation : Index;

/// Where a value comes from at run time: a constant, or a variable slot.
struct ArgSrc
{
    bool isConst;
    uint v;
}

/// How a step reads its relation.
enum StepKind : ubyte
{
    /// Scan the previous round's delta range of the relation (always the first step).
    deltaScan,
    /// Scan the whole snapshot of the relation (nothing is bound).
    scan,
    /// Look up matching tuples through a hash index on the bound positions.
    lookup,
    /// Every argument is bound: a membership test.
    probe
}

/// Require `tuple[pos] == value of src`.
struct Check
{
    uint pos;
    ArgSrc src;
}

/// Bind variable slot `slot` to `tuple[pos]`.
struct Bind
{
    uint pos;
    uint slot;
}

/// A filter attached to a step: a negated atom or a comparison.
struct Filter
{
    bool negated;          // true: `not pred(args)`; false: comparison
    PredId pred;
    ArgSrc[] args;
    CmpOp op;
    ArgSrc lhs, rhs;
}

/// One level of the nested-loop join.
struct Step
{
    StepKind kind;
    PredId pred;
    /// Bit i set when argument position i is bound before this step (lookup/probe).
    uint keyMask;
    /// Values forming the key (lookup) or the whole tuple (probe), in position order.
    ArgSrc[] key;
    /// Newly bound variables.
    Bind[] binds;
    /// Equality checks on the tuple (constants in a delta atom, repeated variables).
    Check[] checks;
    /// Filters whose variables are all bound once this step has run.
    Filter[] filters;
    /// Resolved by the engine before running (lookup steps only).
    Index index;
}

/// A compiled rule variant.
struct Plan
{
    PredId head;
    ArgSrc[] headArgs;
    /// Filters with no variables, evaluated before the first step.
    Filter[] preFilters;
    Step[] steps;
    uint numSlots;
    /// True for a semi-naive variant whose first step is a `deltaScan`.
    bool hasDelta;
}

/// Compile `rule` into a plan. If `deltaLiteral` is non-negative it is the index
/// of the positive body literal that is scanned over the delta range and joined first.
Plan compilePlan(in Rule rule, int deltaLiteral = -1) @safe pure
{
    Plan plan;
    plan.head = rule.head.pred;
    plan.numSlots = rule.numVars;
    plan.hasDelta = deltaLiteral >= 0;

    auto bound = new bool[rule.numVars];

    ArgSrc src(Term t) { return t.isVar ? ArgSrc(false, t.id) : ArgSrc(true, t.id); }
    foreach (t; rule.head.args) plan.headArgs ~= src(t);

    // Positive atoms still to order, filters still to attach.
    size_t[] remaining;
    foreach (i, ref l; rule.body)
        if (l.kind == LiteralKind.positive && cast(int) i != deltaLiteral)
            remaining ~= i;

    struct Pending { Filter f; uint[] vars; }
    Pending[] pending;
    foreach (ref l; rule.body)
    {
        Pending p;
        final switch (l.kind)
        {
        case LiteralKind.positive:
            continue;
        case LiteralKind.negative:
            p.f.negated = true;
            p.f.pred = l.atom.pred;
            foreach (t; l.atom.args)
            {
                p.f.args ~= src(t);
                if (t.isVar) p.vars ~= t.id;
            }
            break;
        case LiteralKind.comparison:
            p.f.op = l.op;
            p.f.lhs = src(l.lhs);
            p.f.rhs = src(l.rhs);
            if (l.lhs.isVar) p.vars ~= l.lhs.id;
            if (l.rhs.isVar) p.vars ~= l.rhs.id;
            break;
        }
        pending ~= p;
    }

    // Attach every pending filter whose variables are all bound.
    void attach(ref Filter[] into)
    {
        Pending[] still;
        foreach (p; pending)
        {
            bool ready = true;
            foreach (v; p.vars) if (!bound[v]) { ready = false; break; }
            if (ready) into ~= p.f; else still ~= p;
        }
        pending = still;
    }
    attach(plan.preFilters);

    void addStep(in Atom atom, bool isDelta)
    {
        Step s;
        s.pred = atom.pred;
        bool[] boundHere = new bool[rule.numVars]; // bound by this very atom
        foreach (pos, t; atom.args)
        {
            immutable isBound = !isDelta && (!t.isVar || bound[t.id]);
            if (isBound)
            {
                s.keyMask |= 1u << pos;
                s.key ~= src(t);
            }
            else if (!t.isVar)
                s.checks ~= Check(cast(uint) pos, src(t));
            else if (boundHere[t.id])
                s.checks ~= Check(cast(uint) pos, ArgSrc(false, t.id));
            else
            {
                boundHere[t.id] = true;
                s.binds ~= Bind(cast(uint) pos, t.id);
            }
        }
        if (isDelta) s.kind = StepKind.deltaScan;
        else if (s.keyMask == (1u << atom.args.length) - 1) s.kind = StepKind.probe;
        else if (s.keyMask != 0) s.kind = StepKind.lookup;
        else s.kind = StepKind.scan;
        foreach (b; s.binds) bound[b.slot] = true;
        attach(s.filters);
        plan.steps ~= s;
    }

    if (deltaLiteral >= 0)
        addStep(rule.body[deltaLiteral].atom, true);

    while (remaining.length)
    {
        size_t bestAt = 0;
        int bestScore = -1;
        foreach (k, li; remaining)
        {
            int score = 0;
            foreach (t; rule.body[li].atom.args)
                if (!t.isVar || bound[t.id]) ++score;
            if (score > bestScore) { bestScore = score; bestAt = k; }
        }
        immutable li = remaining[bestAt];
        remaining = remaining[0 .. bestAt] ~ remaining[bestAt + 1 .. $];
        addStep(rule.body[li].atom, false);
    }
    return plan;
}
