/// Evaluation of bound expressions (a tree-walking interpreter).
module minisql.eval;

import minisql.ast : BinOp;
import minisql.like;
import minisql.plan;
import minisql.value;

/// What an expression sees: the current row of each FROM table (the rows are
/// borrowed, never copied) and the finished aggregates of the current group.
struct EvalCtx
{
    const(Value)[] row0, row1;
    const(Value)[] aggs;
}

/// SQL truth of a value: 1 true, 0 false, -1 unknown (NULL).
int truth(const Value v) pure nothrow @nogc @safe
{
    final switch (v.kind)
    {
    case Kind.null_:
        return -1;
    case Kind.integer:
    case Kind.real_:
        return v.num != 0;
    case Kind.text:
        return 0;
    }
}

private Value fromBool(bool b) pure nothrow @nogc @safe
{
    return Value.makeInt(b ? 1 : 0);
}

private const(char)[] likeText(const Value v, return scope char[] buf) pure nothrow @nogc @safe
{
    if (v.kind == Kind.text)
        return v.str;
    return formatInteger(v.num, buf);
}

/// Evaluates a bound expression. Never fails: all errors are caught at bind
/// time, and division by zero yields NULL.
Value eval(const BExpr e, const ref EvalCtx ctx) pure nothrow @nogc @safe
{
    final switch (e.kind)
    {
    case NodeKind.constant:
        return e.value;
    case NodeKind.column:
        return e.slot == 0 ? ctx.row0[e.col] : ctx.row1[e.col];
    case NodeKind.aggRef:
        return ctx.aggs[e.aggIndex];
    case NodeKind.neg:
        {
            immutable v = eval(e.a, ctx);
            if (v.kind == Kind.integer)
                return Value.makeInt(-cast(ulong) v.num);
            return Value.makeNull();
        }
    case NodeKind.not:
        {
            auto v = eval(e.a, ctx);
            immutable t = truth(v);
            return t < 0 ? Value.makeNull() : fromBool(t == 0);
        }
    case NodeKind.isNull:
        return fromBool(eval(e.a, ctx).kind == Kind.null_);
    case NodeKind.isNotNull:
        return fromBool(eval(e.a, ctx).kind != Kind.null_);
    case NodeKind.binary:
        return evalBinary(e, ctx);
    }
}

private Value evalBinary(const BExpr e, const ref EvalCtx ctx) pure nothrow @nogc @safe
{
    final switch (e.op)
    {
    case BinOp.and:
        {
            auto l = eval(e.a, ctx);
            immutable lt = truth(l);
            if (lt == 0)
                return Value.makeInt(0);
            auto r = eval(e.b, ctx);
            immutable rt = truth(r);
            if (rt == 0)
                return Value.makeInt(0);
            return (lt < 0 || rt < 0) ? Value.makeNull() : Value.makeInt(1);
        }
    case BinOp.or:
        {
            auto l = eval(e.a, ctx);
            immutable lt = truth(l);
            if (lt == 1)
                return Value.makeInt(1);
            auto r = eval(e.b, ctx);
            immutable rt = truth(r);
            if (rt == 1)
                return Value.makeInt(1);
            return (lt < 0 || rt < 0) ? Value.makeNull() : Value.makeInt(0);
        }
    case BinOp.add:
    case BinOp.sub:
    case BinOp.mul:
    case BinOp.div:
    case BinOp.mod:
        {
            immutable l = eval(e.a, ctx);
            immutable r = eval(e.b, ctx);
            if (l.kind != Kind.integer || r.kind != Kind.integer)
                return Value.makeNull();
            immutable x = l.num, y = r.num;
            switch (e.op)
            {
            case BinOp.add:
                return Value.makeInt(cast(long)(cast(ulong) x + cast(ulong) y));
            case BinOp.sub:
                return Value.makeInt(cast(long)(cast(ulong) x - cast(ulong) y));
            case BinOp.mul:
                return Value.makeInt(cast(long)(cast(ulong) x * cast(ulong) y));
            case BinOp.div:
                if (y == 0)
                    return Value.makeNull();
                if (y == -1)
                    return Value.makeInt(-cast(ulong) x);
                return Value.makeInt(x / y);
            default: // mod
                if (y == 0)
                    return Value.makeNull();
                if (y == -1)
                    return Value.makeInt(0);
                return Value.makeInt(x % y);
            }
        }
    case BinOp.eq:
    case BinOp.ne:
    case BinOp.lt:
    case BinOp.le:
    case BinOp.gt:
    case BinOp.ge:
        {
            immutable l = eval(e.a, ctx);
            immutable r = eval(e.b, ctx);
            if (l.kind == Kind.null_ || r.kind == Kind.null_)
                return Value.makeNull();
            immutable c = compareValues(l, r);
            switch (e.op)
            {
            case BinOp.eq:
                return fromBool(c == 0);
            case BinOp.ne:
                return fromBool(c != 0);
            case BinOp.lt:
                return fromBool(c < 0);
            case BinOp.le:
                return fromBool(c <= 0);
            case BinOp.gt:
                return fromBool(c > 0);
            default:
                return fromBool(c >= 0);
            }
        }
    case BinOp.like:
        {
            immutable l = eval(e.a, ctx);
            immutable r = eval(e.b, ctx);
            if (l.kind == Kind.null_ || r.kind == Kind.null_)
                return Value.makeNull();
            char[24] b1 = void, b2 = void;
            return fromBool(likeMatch(likeText(l, b1[]), likeText(r, b2[])));
        }
    }
}

/// True when every conjunct evaluates to true (stops at the first that does not).
bool allTrue(const BExpr[] conjuncts, const ref EvalCtx ctx) pure nothrow @nogc @safe
{
    foreach (c; conjuncts)
    {
        auto v = eval(c, ctx);
        if (truth(v) != 1)
            return false;
    }
    return true;
}
