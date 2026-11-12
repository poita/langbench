/// Predicates: the syntax tree, evaluation and plan selection (SPEC §17).
module tessera.query;

import tessera.bytes;
import tessera.value;

/// Comparison operators of the predicate grammar.
enum CmpOp
{
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
}

/// Node kinds of a predicate tree.
enum PredKind
{
    and,
    or,
    not,
    exists,
    missing,
    compare,
}

/// A node of a predicate tree. `and`/`or` use `lhs` and `rhs`, `not` uses
/// `lhs`; `exists`, `missing` and `compare` use the path; `compare` also uses
/// `op` and `value`.
final class Pred
{
    ///
    PredKind kind;
    ///
    Pred lhs, rhs;
    /// Path segments.
    string[] path;
    /// Path text: the segments joined by `.`.
    string pathText;
    ///
    CmpOp op;
    /// Right-hand side of a comparison.
    Value value;
}

/// Evaluate a predicate against a document (SPEC §17.2).
bool evaluate(const Pred p, const Value doc)
{
    final switch (p.kind)
    {
    case PredKind.and:
        return evaluate(p.lhs, doc) && evaluate(p.rhs, doc);
    case PredKind.or:
        return evaluate(p.lhs, doc) || evaluate(p.rhs, doc);
    case PredKind.not:
        return !evaluate(p.lhs, doc);
    case PredKind.exists:
        return resolvePath(doc, p.path) !is null;
    case PredKind.missing:
        return resolvePath(doc, p.path) is null;
    case PredKind.compare:
        auto x = resolvePath(doc, p.path);
        if (x is null)
            return false;
        return compareHolds(*x, p.op, p.value);
    }
}

/// `x op rhs` for a present `x`.
bool compareHolds(const Value x, CmpOp op, const Value rhs) @safe pure nothrow
{
    if (op == CmpOp.eq)
        return deepEqual(x, rhs);
    if (op == CmpOp.ne)
        return !deepEqual(x, rhs);
    if (x.kind != rhs.kind || x.kind == Kind.list || x.kind == Kind.object)
        return false;
    immutable c = compareScalars(x, rhs);
    final switch (op)
    {
    case CmpOp.lt:
        return c < 0;
    case CmpOp.le:
        return c <= 0;
    case CmpOp.gt:
        return c > 0;
    case CmpOp.ge:
        return c >= 0;
    case CmpOp.eq, CmpOp.ne:
        assert(0);
    }
}

/// Flatten the top-level `and` nodes of a predicate into its leaves, left to
/// right (SPEC §17.3 step 1).
Pred[] flattenAnd(Pred root)
{
    Pred[] leaves;
    void visit(Pred p)
    {
        if (p.kind == PredKind.and)
        {
            visit(p.lhs);
            visit(p.rhs);
        }
        else
            leaves ~= p;
    }

    visit(root);
    return leaves;
}

/// The leaf `find` drives an index with, or `null` for a scan plan
/// (SPEC §17.3). `hasIndex` says whether a live index exists on a path text.
Pred chooseIndexLeaf(Pred root, scope bool delegate(string) hasIndex)
{
    Pred chosen = null;
    foreach (leaf; flattenAnd(root))
    {
        if (leaf.kind != PredKind.compare || leaf.op == CmpOp.ne)
            continue;
        if (leaf.value.kind == Kind.list || leaf.value.kind == Kind.object)
            continue;
        if (!hasIndex(leaf.pathText))
            continue;
        if (chosen is null)
        {
            chosen = leaf;
            continue;
        }
        immutable leafEq = leaf.op == CmpOp.eq;
        immutable chosenEq = chosen.op == CmpOp.eq;
        if (leafEq != chosenEq)
        {
            if (leafEq)
                chosen = leaf;
            continue;
        }
        if (compareBytes(asBytes(leaf.pathText), asBytes(chosen.pathText)) < 0)
            chosen = leaf;
    }
    return chosen;
}

@safe pure nothrow unittest
{
    auto n = Value.nul();
    auto one = Value.integer(1);
    assert(!compareHolds(n, CmpOp.lt, n));
    assert(compareHolds(n, CmpOp.le, n));
    assert(compareHolds(n, CmpOp.ge, n));
    assert(!compareHolds(n, CmpOp.eq, one));
    assert(compareHolds(n, CmpOp.ne, one));
    assert(!compareHolds(n, CmpOp.lt, one));
    assert(compareHolds(Value.boolean(false), CmpOp.lt, Value.boolean(true)));
    assert(compareHolds(Value.text("b"), CmpOp.gt, Value.text("a")));
    assert(!compareHolds(Value.list(null), CmpOp.le, Value.list(null)));
    assert(compareHolds(Value.list(null), CmpOp.eq, Value.list(null)));
}
