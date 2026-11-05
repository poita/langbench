/// Predicate evaluation and plan selection.
module tessera.query;

import tessera.ast;
import tessera.bytes;
import tessera.header;
import tessera.lexer : CmpOp;
import tessera.value;

/// Does `doc` satisfy the predicate?
bool matches(Pred p, Value doc) pure nothrow @safe
{
    final switch (p.kind)
    {
    case PredKind.and:
        return matches(p.kids[0], doc) && matches(p.kids[1], doc);
    case PredKind.or:
        return matches(p.kids[0], doc) || matches(p.kids[1], doc);
    case PredKind.not:
        return !matches(p.kids[0], doc);
    case PredKind.exists:
        return resolvePath(doc, p.path) !is null;
    case PredKind.missing:
        return resolvePath(doc, p.path) is null;
    case PredKind.compare:
        auto x = resolvePath(doc, p.path);
        if (x is null)
            return false;
        return compareHolds(*x, p.op, p.rhs);
    }
}

/// Evaluate `x op rhs` for a present left-hand side.
bool compareHolds(Value x, CmpOp op, Value rhs) pure nothrow @safe
{
    if (op == CmpOp.eq)
        return valuesEqual(x, rhs);
    if (op == CmpOp.ne)
        return !valuesEqual(x, rhs);
    if (x.kind != rhs.kind || x.kind == Kind.list || x.kind == Kind.object)
        return false;
    immutable c = compareScalars(x, rhs);
    final switch (op)
    {
    case CmpOp.lt: return c < 0;
    case CmpOp.le: return c <= 0;
    case CmpOp.gt: return c > 0;
    case CmpOp.ge: return c >= 0;
    case CmpOp.eq:
    case CmpOp.ne:
        return false;
    }
}

/// The access path chosen for a `find`.
struct Plan
{
    /// True for an index plan.
    bool useIndex;
    /// Slot of the chosen index.
    size_t slot;
    /// Path text of the chosen index.
    string path;
    /// The comparison that selected it.
    Pred leaf;
}

private void flatten(Pred p, ref Pred[] leaves) pure nothrow @safe
{
    if (p.kind == PredKind.and)
    {
        flatten(p.kids[0], leaves);
        flatten(p.kids[1], leaves);
    }
    else
        leaves ~= p;
}

/// Choose the plan for a predicate against the live indexes (§17.3).
Plan choosePlan(Pred root, const ref Header h) pure nothrow @safe
{
    Pred[] leaves;
    flatten(root, leaves);
    Plan best;
    foreach (leaf; leaves)
    {
        if (leaf.kind != PredKind.compare || leaf.op == CmpOp.ne)
            continue;
        if (leaf.rhs.kind == Kind.list || leaf.rhs.kind == Kind.object)
            continue;
        immutable text = leaf.pathText;
        size_t slot = size_t.max;
        foreach (s, ref sl; h.slots)
            if (sl.live && sl.path == text)
                slot = s;
        if (slot == size_t.max)
            continue;
        bool better = !best.useIndex;
        if (best.useIndex)
        {
            immutable bestEq = best.leaf.op == CmpOp.eq;
            immutable thisEq = leaf.op == CmpOp.eq;
            if (thisEq != bestEq)
                better = thisEq;
            else
                better = compareBytes(asBytes(text), asBytes(best.path)) < 0;
        }
        if (better)
            best = Plan(true, slot, text, leaf);
    }
    return best;
}
