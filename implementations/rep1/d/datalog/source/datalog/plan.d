/// Compilation of rules into join plans.
module datalog.plan;

import datalog.ast;
import datalog.relation;

/// What to do with one argument position of a positive body atom.
enum OpKind : ubyte
{
    constant, /// the tuple value must equal `val`
    variable, /// the tuple value must equal variable slot `val` (already bound)
    bind /// store the tuple value into variable slot `val`
}

/// An argument-position action.
struct ArgOp
{
    OpKind kind;
    uint val;
    uint pos; /// argument position in the atom
}

/// How a step reads its relation.
enum StepKind : ubyte
{
    scan, /// iterate a position range
    lookup, /// hash-index lookup on the bound positions
    probe /// every argument is bound: one membership test
}

/// A negated atom or comparison, evaluated as soon as its variables are bound.
struct Filter
{
    bool negated; /// negated atom if true, otherwise a comparison
    uint pred;
    Term[] args;
    CmpOp op;
    Term lhs, rhs;
}

/// One nested-loop level of a join.
struct Step
{
    StepKind kind;
    bool isDelta; /// scan only the previous round's delta range
    uint pred;
    ArgOp[] keyOps; /// lookup: key values in column order; probe: the whole tuple
    ArgOp[] matchOps; /// scan/lookup: checks and bindings applied to each fetched tuple
    Index index; /// lookup only
    Filter[] after; /// filters to apply once this step has bound its variables
}

/// A compiled rule variant.
struct Plan
{
    uint headPred;
    Term[] head;
    uint numVars;
    Filter[] initial; /// filters that need no variables bound
    Step[] steps;
    Index[] indexes; /// every index used by the steps
}

/// Compile `rule` into a join plan.
///
/// `deltaLiteral` is the body position of the positive atom to scan over the
/// delta range (placed first), or -1 for the full plan. Indexes the plan needs
/// are created on `relations` (but not populated).
Plan compilePlan(const Program program, ref const Rule rule, int deltaLiteral, Relation[] relations) @safe
{
    Plan plan;
    plan.headPred = rule.head.pred;
    plan.head = rule.head.args.dup;
    plan.numVars = rule.numVars;

    auto bound = new bool[rule.numVars];

    const order = orderAtoms(rule, deltaLiteral);

    // Per-step variable-bound-after snapshots, used to attach filters.
    bound[] = false;
    bool[][] boundAfter;
    foreach (bi; order)
    {
        ref const atom = rule.body[bi].atom;
        Step step;
        step.pred = atom.pred;
        step.isDelta = (cast(int) bi == deltaLiteral);

        bool allBound = true;
        uint keyMask = 0;
        auto seen = bound.dup; // variables bound before or within this atom
        ArgOp[] ops;
        foreach (j, t; atom.args)
        {
            if (!t.isVariable)
            {
                ops ~= ArgOp(OpKind.constant, t.id, cast(uint) j);
                keyMask |= 1u << j;
            }
            else if (bound[t.id])
            {
                ops ~= ArgOp(OpKind.variable, t.id, cast(uint) j);
                keyMask |= 1u << j;
            }
            else if (seen[t.id])
            {
                ops ~= ArgOp(OpKind.variable, t.id, cast(uint) j); // repeated within the atom
                allBound = false;
            }
            else
            {
                ops ~= ArgOp(OpKind.bind, t.id, cast(uint) j);
                seen[t.id] = true;
                allBound = false;
            }
        }

        if (step.isDelta)
        {
            step.kind = StepKind.scan;
            step.matchOps = ops;
        }
        else if (allBound)
        {
            step.kind = StepKind.probe;
            step.keyOps = ops;
        }
        else if (keyMask != 0)
        {
            step.kind = StepKind.lookup;
            foreach (op; ops)
                if (keyMask & (1u << op.pos))
                    step.keyOps ~= op;
                else
                    step.matchOps ~= op;
            step.index = relations[atom.pred].index(keyMask);
            plan.indexes ~= step.index;
        }
        else
        {
            step.kind = StepKind.scan;
            step.matchOps = ops;
        }

        bound = seen;
        boundAfter ~= bound.dup;
        plan.steps ~= step;
    }

    // Attach negations and comparisons at the earliest step binding all their variables.
    foreach (ref lit; rule.body)
    {
        if (lit.kind == LiteralKind.positive)
            continue;
        Filter f;
        Term[] terms;
        if (lit.kind == LiteralKind.negative)
        {
            f.negated = true;
            f.pred = lit.atom.pred;
            f.args = lit.atom.args.dup;
            terms = f.args;
        }
        else
        {
            f.op = lit.op;
            f.lhs = lit.lhs;
            f.rhs = lit.rhs;
            terms = [lit.lhs, lit.rhs];
        }
        int at = -1;
        for (; at < cast(int) boundAfter.length; ++at)
        {
            bool ok = true;
            foreach (t; terms)
                if (t.isVariable && (at < 0 || !boundAfter[at][t.id]))
                    ok = false;
            if (ok)
                break;
        }
        // Safety guarantees every variable is eventually bound.
        assert(at < cast(int) boundAfter.length, "unsafe rule reached the planner");
        if (at < 0)
            plan.initial ~= f;
        else
            plan.steps[at].after ~= f;
    }
    return plan;
}

/// Order the positive atoms of `rule`: the delta atom (if any) first, then greedily the
/// atom with the most bound arguments (constants or already-bound variables), ties by body order.
private size_t[] orderAtoms(ref const Rule rule, int deltaLiteral) @safe
{
    auto bound = new bool[rule.numVars];
    size_t[] order;

    void place(size_t bodyIndex)
    {
        order ~= bodyIndex;
        foreach (t; rule.body[bodyIndex].atom.args)
            if (t.isVariable)
                bound[t.id] = true;
    }

    size_t[] remaining;
    foreach (i, ref lit; rule.body)
        if (lit.kind == LiteralKind.positive && cast(int) i != deltaLiteral)
            remaining ~= i;
    if (deltaLiteral >= 0)
        place(cast(size_t) deltaLiteral);

    while (remaining.length)
    {
        size_t best = 0;
        int bestScore = -1;
        foreach (k, bi; remaining)
        {
            int score = 0;
            foreach (t; rule.body[bi].atom.args)
                if (!t.isVariable || bound[t.id])
                    ++score;
            if (score > bestScore)
            {
                bestScore = score;
                best = k;
            }
        }
        immutable chosen = remaining[best];
        remaining = remaining[0 .. best] ~ remaining[best + 1 .. $];
        place(chosen);
    }
    return order;
}
