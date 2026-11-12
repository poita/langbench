/// Compilation of rules into join plans.
module datalog.plan;

import datalog.ast;
import datalog.relation;

/// What to do with one column of a candidate row.
enum OpKind : ubyte
{
    eqConst, /// the column must equal a constant rank
    eqSlot, /// the column must equal the variable slot's value
    bind, /// store the column into the variable slot
}

/// One per-column operation of a join step.
struct ArgOp
{
    OpKind kind;
    ubyte col;
    /// For `eqConst`/`eqSlot`: the value is known before the step starts, so
    /// the column is part of the index key.
    bool inKey;
    uint value; /// constant rank or slot number
}

/// Which rows of a predicate a step may read in the current round.
enum Window : ubyte
{
    all, /// everything that existed at the start of the round (old and delta)
    old, /// only rows older than the round's delta
    delta, /// only the rows added by the previous round
}

/// A constant rank or a variable slot.
struct Operand
{
    bool isConst;
    uint value;
}

/// A filter run as soon as its variables are bound: a comparison or a negated atom.
struct Filter
{
    bool negation;
    CmpOp op; // comparison
    Operand lhs, rhs; // comparison
    uint predicate; // negation
    Operand[] args; // negation
}

/// One nested-loop level: read the rows of `predicate` in `window` matching
/// the bound columns, bind the new variables, then apply `filters`.
struct Step
{
    uint predicate;
    Window window;
    ArgOp[] ops; /// in column order
    uint mask; /// bound columns (key of the index); 0 means scan
    size_t indexNo; /// number of the index in the relation when `mask != 0`
    Operand[] key; /// key operands in column order
    Filter[] filters;
}

/// An executable form of a rule (or of one delta variant of a rule).
struct JoinPlan
{
    uint headPredicate;
    Operand[] head;
    uint numSlots;
    Filter[] preFilters; /// filters without variables, checked before the first step
    Step[] steps;
}

private uint[] variablesOf(const Literal lit) @safe pure nothrow
{
    uint[] vs;
    void add(Term t)
    {
        if (t.kind == TermKind.variable)
            vs ~= t.id;
    }

    final switch (lit.kind)
    {
    case LiteralKind.positive:
    case LiteralKind.negated:
        foreach (t; lit.atom.args)
            add(t);
        break;
    case LiteralKind.comparison:
        add(lit.lhs);
        add(lit.rhs);
        break;
    }
    return vs;
}

private Operand operandOf(Term t, const(uint)[] rank) @safe pure nothrow
{
    return t.kind == TermKind.constant ? Operand(true, rank[t.id]) : Operand(false, t.id);
}

/// Compiles `rule` into a plan.
///
/// Params:
///   program = the program the rule belongs to
///   rule = a safe rule with a non-empty body
///   deltaLiteral = index into `rule.body` of the positive literal that reads
///       the delta, or -1 for a plan that reads everything
///   inStratum = per predicate: whether it belongs to the stratum being evaluated
///   rank = constant id -> rank
///   relations = per predicate relation; the indexes the plan needs are created here
JoinPlan compileRule(const Program program, ref const Rule rule, int deltaLiteral,
    const(bool)[] inStratum, const(uint)[] rank, Relation[] relations) @safe pure
{
    JoinPlan plan;
    plan.headPredicate = rule.head.predicate;
    plan.numSlots = rule.numVars;
    foreach (t; rule.head.args)
        plan.head ~= operandOf(t, rank);

    auto bound = new bool[rule.numVars];
    size_t[] remaining;
    foreach (i, ref lit; rule.body)
        if (lit.kind == LiteralKind.positive)
            remaining ~= i;

    // Filters still waiting for their variables.
    size_t[] pending;
    foreach (i, ref lit; rule.body)
        if (lit.kind != LiteralKind.positive)
            pending ~= i;

    Filter makeFilter(ref const Literal lit)
    {
        Filter f;
        if (lit.kind == LiteralKind.negated)
        {
            f.negation = true;
            f.predicate = lit.atom.predicate;
            foreach (t; lit.atom.args)
                f.args ~= operandOf(t, rank);
        }
        else
        {
            f.op = lit.op;
            f.lhs = operandOf(lit.lhs, rank);
            f.rhs = operandOf(lit.rhs, rank);
        }
        return f;
    }

    // Moves the filters that have all their variables bound into `into`.
    void releaseFilters(ref Filter[] into)
    {
        size_t[] still;
        foreach (i; pending)
        {
            bool ready = true;
            foreach (v; variablesOf(rule.body[i]))
                ready = ready && bound[v];
            if (ready)
                into ~= makeFilter(rule.body[i]);
            else
                still ~= i;
        }
        pending = still;
    }

    releaseFilters(plan.preFilters);

    bool first = true;
    while (remaining.length)
    {
        // Choose the next atom: the delta atom first, then the one with most
        // bound arguments, ties in body order.
        size_t bestPos = 0;
        if (first && deltaLiteral >= 0)
        {
            foreach (k, li; remaining)
                if (li == deltaLiteral)
                    bestPos = k;
        }
        else
        {
            int bestScore = -1;
            foreach (k, li; remaining)
            {
                int score;
                foreach (t; rule.body[li].atom.args)
                    if (t.kind == TermKind.constant || bound[t.id])
                        ++score;
                if (score > bestScore)
                {
                    bestScore = score;
                    bestPos = k;
                }
            }
        }
        immutable li = remaining[bestPos];
        remaining = remaining[0 .. bestPos] ~ remaining[bestPos + 1 .. $];
        first = false;

        ref const lit = rule.body[li];
        Step step;
        step.predicate = lit.atom.predicate;
        if (cast(int) li == deltaLiteral)
            step.window = Window.delta;
        else if (deltaLiteral >= 0 && inStratum[step.predicate] && cast(int) li < deltaLiteral)
            step.window = Window.old;
        else
            step.window = Window.all;

        const boundBefore = bound.dup;
        foreach (col, t; lit.atom.args)
        {
            ArgOp op;
            op.col = cast(ubyte) col;
            if (t.kind == TermKind.constant)
            {
                op.kind = OpKind.eqConst;
                op.value = rank[t.id];
                op.inKey = true;
            }
            else if (boundBefore[t.id])
            {
                op.kind = OpKind.eqSlot;
                op.value = t.id;
                op.inKey = true;
            }
            else if (bound[t.id])
            {
                op.kind = OpKind.eqSlot; // repeated within this atom
                op.value = t.id;
            }
            else
            {
                op.kind = OpKind.bind;
                op.value = t.id;
                bound[t.id] = true;
            }
            if (op.inKey)
            {
                step.mask |= 1u << col;
                step.key ~= Operand(op.kind == OpKind.eqConst, op.value);
            }
            step.ops ~= op;
        }
        if (step.mask != 0 && step.window != Window.delta)
            step.indexNo = relations[step.predicate].indexFor(step.mask);
        releaseFilters(step.filters);
        plan.steps ~= step;
    }
    return plan;
}

@safe pure unittest
{
    import datalog.parser : parseProgram;

    auto prog = parseProgram("p(X, Z) :- q(X, Y), r(Y, Z), not s(Z), X < Z. p(1, 2) :- not s(1).");
    auto rank = prog.symbols.ranks;
    auto rels = new Relation[prog.predicates.length];
    foreach (i, p; prog.predicates)
        rels[i] = new Relation(p.arity);
    auto inStratum = new bool[prog.predicates.length];

    auto plan = compileRule(prog, prog.rules[0], -1, inStratum, rank, rels);
    assert(plan.steps.length == 2);
    // q is first (no bound arguments anywhere, body order); r then has Y bound.
    assert(prog.predicates[plan.steps[0].predicate].name == "q");
    assert(plan.steps[0].mask == 0);
    assert(plan.steps[1].mask == 0b01);
    assert(plan.steps[0].filters.length == 0);
    assert(plan.steps[1].filters.length == 2); // `not s(Z)` and `X < Z`

    // Delta on r: r goes first, then q probes on Y.
    auto delta = compileRule(prog, prog.rules[0], 1, inStratum, rank, rels);
    assert(prog.predicates[delta.steps[0].predicate].name == "r");
    assert(delta.steps[0].window == Window.delta);
    assert(delta.steps[1].mask == 0b10);

    // A body without positive atoms has only pre-filters.
    auto bodyless = compileRule(prog, prog.rules[1], -1, inStratum, rank, rels);
    assert(bodyless.steps.length == 0 && bodyless.preFilters.length == 1);
}
