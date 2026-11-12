/**
 * Bound expressions and their interpreter.
 *
 * A $(LREF BExpr) is an expression whose column references have been resolved
 * to a (table slot, column index) pair and whose aggregate calls have been
 * numbered. It is evaluated directly from the tree, with no compilation or
 * constant folding.
 */
module minisql.expr;

import minisql.ast : AggFunc, BinOp;
import minisql.like;
import minisql.value;

/// The shape of a bound node.
enum BKind : ubyte
{
    literal, column, negate, not, binary, isNull, isNotNull, like, aggregate,
}

/// A bound expression node.
final class BExpr
{
    BKind kind;
    BinOp op;
    Value value;
    /// For columns: which FROM table (0 or 1) and which column of it.
    int slot, column;
    /// For aggregates: index into the query's aggregate list.
    int aggIndex;
    BExpr lhs, rhs;

    this(BKind kind) @safe pure nothrow @nogc
    {
        this.kind = kind;
    }
}

/// An aggregate call found in a query.
struct AggSpec
{
    AggFunc func;
    /// The argument, or null for `COUNT(*)`.
    BExpr arg;
}

/// What an expression is evaluated against.
struct EvalContext
{
    /// The current row of each FROM table (empty slices where unused).
    const(Value)[][2] rows;
    /// Finished aggregate results of the current group, by `aggIndex`.
    const(Value)[] aggregates;
}

/// Bit mask of the FROM tables (bit 0 / bit 1) that `e` reads columns of.
uint tableMask(const BExpr e) @safe pure nothrow @nogc
{
    if (e is null)
        return 0;
    if (e.kind == BKind.column)
        return 1u << e.slot;
    return tableMask(e.lhs) | tableMask(e.rhs);
}

/// Splits `e` at top-level ANDs into `out_`.
void splitConjuncts(BExpr e, ref BExpr[] out_) @safe pure nothrow
{
    if (e is null)
        return;
    if (e.kind == BKind.binary && e.op == BinOp.and)
    {
        splitConjuncts(e.lhs, out_);
        splitConjuncts(e.rhs, out_);
    }
    else
        out_ ~= e;
}

private Value fromBool(bool b) @safe pure nothrow @nogc
{
    return Value.integer(b ? 1 : 0);
}

private Value arithmetic(BinOp op, in Value a, in Value b) @safe pure nothrow @nogc
{
    if (a.kind != ValueKind.integer || b.kind != ValueKind.integer)
        return Value.null_;
    immutable x = a.num, y = b.num;
    final switch (op)
    {
    case BinOp.add:
        return Value.integer(x + y);
    case BinOp.sub:
        return Value.integer(x - y);
    case BinOp.mul:
        return Value.integer(x * y);
    case BinOp.div:
        if (y == 0)
            return Value.null_;
        if (y == -1)
            return Value.integer(-x);
        return Value.integer(x / y);
    case BinOp.mod:
        if (y == 0)
            return Value.null_;
        if (y == -1)
            return Value.integer(0);
        return Value.integer(x % y);
    case BinOp.eq, BinOp.ne, BinOp.lt, BinOp.le, BinOp.gt, BinOp.ge, BinOp.and, BinOp.or:
        assert(0);
    }
}

private Value comparison(BinOp op, in Value a, in Value b) @safe pure nothrow @nogc
{
    if (a.isNull || b.isNull)
        return Value.null_;
    immutable c = compareValues(a, b);
    final switch (op)
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
    case BinOp.ge:
        return fromBool(c >= 0);
    case BinOp.add, BinOp.sub, BinOp.mul, BinOp.div, BinOp.mod, BinOp.and, BinOp.or:
        assert(0);
    }
}

private Value like(in Value s, in Value p) @safe pure
{
    if (s.isNull || p.isNull)
        return Value.null_;
    // INTEGER operands are matched by their decimal text.
    return fromBool(likeMatch(s.kind == ValueKind.text ? s.str : toText(s),
            p.kind == ValueKind.text ? p.str : toText(p)));
}

/// Evaluates `e` against `ctx`. Evaluation never fails: errors such as
/// division by zero yield NULL.
Value evaluate(const BExpr e, ref const EvalContext ctx) @safe
{
    final switch (e.kind)
    {
    case BKind.literal:
        return e.value;
    case BKind.column:
        return ctx.rows[e.slot][e.column];
    case BKind.negate:
    {
        immutable v = evaluate(e.lhs, ctx);
        if (v.kind == ValueKind.integer)
            return Value.integer(-v.num);
        return Value.null_;
    }
    case BKind.not:
    {
        immutable t = truthOf(evaluate(e.lhs, ctx));
        final switch (t)
        {
        case Truth.true_:
            return Value.integer(0);
        case Truth.false_:
            return Value.integer(1);
        case Truth.unknown:
            return Value.null_;
        }
    }
    case BKind.isNull:
        return fromBool(evaluate(e.lhs, ctx).isNull);
    case BKind.isNotNull:
        return fromBool(!evaluate(e.lhs, ctx).isNull);
    case BKind.like:
        return like(evaluate(e.lhs, ctx), evaluate(e.rhs, ctx));
    case BKind.aggregate:
        return ctx.aggregates[e.aggIndex];
    case BKind.binary:
        switch (e.op)
        {
        case BinOp.and:
        {
            immutable l = truthOf(evaluate(e.lhs, ctx));
            if (l == Truth.false_)
                return Value.integer(0);
            immutable r = truthOf(evaluate(e.rhs, ctx));
            if (r == Truth.false_)
                return Value.integer(0);
            if (l == Truth.unknown || r == Truth.unknown)
                return Value.null_;
            return Value.integer(1);
        }
        case BinOp.or:
        {
            immutable l = truthOf(evaluate(e.lhs, ctx));
            if (l == Truth.true_)
                return Value.integer(1);
            immutable r = truthOf(evaluate(e.rhs, ctx));
            if (r == Truth.true_)
                return Value.integer(1);
            if (l == Truth.unknown || r == Truth.unknown)
                return Value.null_;
            return Value.integer(0);
        }
        case BinOp.add, BinOp.sub, BinOp.mul, BinOp.div, BinOp.mod:
            return arithmetic(e.op, evaluate(e.lhs, ctx), evaluate(e.rhs, ctx));
        default:
            return comparison(e.op, evaluate(e.lhs, ctx), evaluate(e.rhs, ctx));
        }
    }
}

/// True if `e` evaluates to true (NULL and zero are not).
bool isTrue(const BExpr e, ref const EvalContext ctx) @safe
{
    return truthOf(evaluate(e, ctx)) == Truth.true_;
}

version (unittest)
{
    private BExpr lit(Value v)
    {
        auto e = new BExpr(BKind.literal);
        e.value = v;
        return e;
    }

    private BExpr bin(BinOp op, BExpr l, BExpr r)
    {
        auto e = new BExpr(BKind.binary);
        e.op = op;
        e.lhs = l;
        e.rhs = r;
        return e;
    }

    private Value ev(BExpr e)
    {
        EvalContext c;
        return evaluate(e, c);
    }

    private BExpr i(long v)
    {
        return lit(Value.integer(v));
    }
}

@("integer arithmetic truncates toward zero and divides by zero to NULL")
unittest
{
    assert(ev(bin(BinOp.div, i(-7), i(2))).num == -3);
    assert(ev(bin(BinOp.mod, i(-7), i(3))).num == -1);
    assert(ev(bin(BinOp.mod, i(7), i(-3))).num == 1);
    assert(ev(bin(BinOp.div, i(1), i(0))).isNull);
    assert(ev(bin(BinOp.mod, i(1), i(0))).isNull);
    assert(ev(bin(BinOp.add, i(1), lit(Value.null_))).isNull);
}

@("three-valued AND / OR")
unittest
{
    auto n = lit(Value.null_);
    assert(ev(bin(BinOp.and, i(0), n)).num == 0);
    assert(ev(bin(BinOp.and, i(1), n)).isNull);
    assert(ev(bin(BinOp.or, i(1), n)).num == 1);
    assert(ev(bin(BinOp.or, i(0), n)).isNull);
    assert(ev(bin(BinOp.or, n, n)).isNull);
}

@("comparisons across kinds")
unittest
{
    assert(ev(bin(BinOp.eq, i(1), lit(Value.text("1")))).num == 0);
    assert(ev(bin(BinOp.lt, i(100), lit(Value.text("0")))).num == 1);
    assert(ev(bin(BinOp.eq, lit(Value.null_), lit(Value.null_))).isNull);
}
