/// Execution of join plans.
module datalog.exec;

import datalog.ast : CmpOp;
import datalog.plan;
import datalog.relation;

/// Evaluates a comparison between two constant ranks.
bool compare(CmpOp op, uint a, uint b) @safe pure nothrow @nogc
{
    final switch (op)
    {
    case CmpOp.lt: return a < b;
    case CmpOp.le: return a <= b;
    case CmpOp.gt: return a > b;
    case CmpOp.ge: return a >= b;
    case CmpOp.eq: return a == b;
    case CmpOp.ne: return a != b;
    }
}

/// Runs `JoinPlan`s against a set of relations, inserting the derived head
/// tuples into the head relation.
///
/// `windowStart[p]` / `windowEnd[p]` give, per predicate, the delta rows
/// `[windowStart, windowEnd)`; rows below `windowStart` are old. Rows at or
/// beyond `windowEnd` (added during the current round) are never read.
struct Executor
{
    Relation[] relations;
    size_t[] windowStart;
    size_t[] windowEnd;

    private const(JoinPlan)* plan;
    private Relation headRelation;
    private uint[] slots;
    private uint[] scratch;
    private size_t derived;

    /// Runs `p`; returns the number of new tuples it added.
    size_t run(ref const JoinPlan p) @trusted
    {
        plan = &p;
        headRelation = relations[p.headPredicate];
        slots.length = p.numSlots;
        scratch.length = 8 > headRelation.arity ? 8 : headRelation.arity;
        derived = 0;
        foreach (ref f; p.preFilters)
            if (!passes(f))
                return 0;
        step(0);
        return derived;
    }

    private uint value(Operand o) const @safe pure nothrow @nogc
    {
        return o.isConst ? o.value : slots[o.value];
    }

    private bool passes(ref const Filter f) @safe nothrow
    {
        if (!f.negation)
            return compare(f.op, value(f.lhs), value(f.rhs));
        if (scratch.length < f.args.length)
            scratch.length = f.args.length;
        // Negated atoms are checked with a private buffer: `scratch` is only
        // used while no emit is in progress, so reuse is safe.
        foreach (i, a; f.args)
            scratch[i] = value(a);
        return !relations[f.predicate].contains(scratch[0 .. f.args.length]);
    }

    private void step(size_t si) @trusted
    {
        if (si == plan.steps.length)
        {
            emit();
            return;
        }
        auto st = &plan.steps[si];
        auto rel = relations[st.predicate];
        size_t lo = 0, hi;
        final switch (st.window)
        {
        case Window.all:
            hi = windowEnd[st.predicate];
            break;
        case Window.old:
            hi = windowStart[st.predicate];
            break;
        case Window.delta:
            lo = windowStart[st.predicate];
            hi = windowEnd[st.predicate];
            break;
        }

        if (st.mask == 0 || st.window == Window.delta)
        {
            foreach (r; lo .. hi)
                tryRow(si, st, rel, r);
            return;
        }
        ulong h = hashSeed;
        foreach (o; st.key)
            h = mixHash(h, value(o));
        auto ix = &rel.indexes[st.indexNo];
        for (uint r = ix.heads[h & (ix.heads.length - 1)]; r != none; r = ix.next[r])
            if (r < hi)
                tryRow(si, st, rel, r);
    }

    private void tryRow(size_t si, const(Step)* st, Relation rel, size_t r) @trusted
    {
        const(uint)* row = rel.data.ptr + r * rel.arity;
        foreach (ref op; st.ops)
        {
            final switch (op.kind)
            {
            case OpKind.eqConst:
                if (row[op.col] != op.value)
                    return;
                break;
            case OpKind.eqSlot:
                if (row[op.col] != slots[op.value])
                    return;
                break;
            case OpKind.bind:
                slots[op.value] = row[op.col];
                break;
            }
        }
        foreach (ref f; st.filters)
            if (!passes(f))
                return;
        step(si + 1);
    }

    private void emit() @trusted
    {
        // `scratch` may have been used by a negation filter, but that use is
        // finished by now; head tuples are built afresh.
        auto n = plan.head.length;
        foreach (i, o; plan.head)
            scratch[i] = value(o);
        if (headRelation.insert(scratch[0 .. n]))
            ++derived;
    }
}
