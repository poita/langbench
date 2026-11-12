/**
 * Formula evaluation.
 *
 * Evaluation walks a syntax tree and reads the *stored* values of the cells
 * it references through a lookup callback; it never evaluates other cells.
 */
module spreadsheet.eval;

import std.math : isFinite;
import spreadsheet.ast;
import spreadsheet.cellref;
import spreadsheet.value;

/// Callback giving the current value of the cell with the given key (empty if unset).
alias CellLookup = Value delegate(uint key) @safe;

private Value err(ErrorCode c) pure nothrow @nogc @safe
{
    return Value.makeError(c);
}

/**
 * Evaluates `e`.
 *
 * The result may be empty (a reference to an empty cell, passed through
 * parentheses and `IF`); callers storing a formula's result turn that
 * into the number 0.
 */
Value evaluate(const Expr e, scope CellLookup lookup) @safe
{
    final switch (e.kind)
    {
    case ExprKind.number:
    case ExprKind.text:
    case ExprKind.error:
        return e.value;
    case ExprKind.reference:
        return lookup(e.cell.key);
    case ExprKind.range:
        // Ranges are only legal as aggregate arguments; the parser never produces
        // one elsewhere.
        return err(ErrorCode.value);
    case ExprKind.negate:
    {
        double x;
        Value bad;
        if (!toNumber(evaluate(e.args[0], lookup), x, bad))
            return bad;
        return Value.makeNumber(-x);
    }
    case ExprKind.binary:
        return evalBinary(e, lookup);
    case ExprKind.conditional:
    {
        double c;
        Value bad;
        if (!toNumber(evaluate(e.args[0], lookup), c, bad))
            return bad;
        return evaluate(e.args[c != 0 ? 1 : 2], lookup);
    }
    case ExprKind.aggregate:
        return evalAggregate(e, lookup);
    }
}

/**
 * Arithmetic coercion: an empty value counts as 0.  Returns `false` and sets
 * `failure` for an error (passed through) or a string (`#VALUE!`).
 */
private bool toNumber(const Value v, out double x, out Value failure) pure nothrow @nogc @safe
{
    final switch (v.kind)
    {
    case ValueKind.number:
        x = v.number;
        return true;
    case ValueKind.empty:
        x = 0;
        return true;
    case ValueKind.text:
        failure = err(ErrorCode.value);
        return false;
    case ValueKind.error:
        failure = v;
        return false;
    }
}

private Value evalBinary(const Expr e, scope CellLookup lookup) @safe
{
    final switch (e.op)
    {
    case BinaryOp.add:
    case BinaryOp.sub:
    case BinaryOp.mul:
    case BinaryOp.div:
    {
        double a, b;
        Value bad;
        if (!toNumber(evaluate(e.args[0], lookup), a, bad))
            return bad;
        if (!toNumber(evaluate(e.args[1], lookup), b, bad))
            return bad;
        double r;
        switch (e.op)
        {
        case BinaryOp.add: r = a + b; break;
        case BinaryOp.sub: r = a - b; break;
        case BinaryOp.mul: r = a * b; break;
        default:
            if (b == 0)
                return err(ErrorCode.divZero);
            r = a / b;
            break;
        }
        return isFinite(r) ? Value.makeNumber(r) : err(ErrorCode.value);
    }
    case BinaryOp.concat:
    {
        const a = evaluate(e.args[0], lookup);
        if (a.isError)
            return a;
        const b = evaluate(e.args[1], lookup);
        if (b.isError)
            return b;
        return Value.makeText(textForm(a) ~ textForm(b));
    }
    case BinaryOp.eq:
    case BinaryOp.ne:
    case BinaryOp.lt:
    case BinaryOp.gt:
    case BinaryOp.le:
    case BinaryOp.ge:
    {
        Value a = evaluate(e.args[0], lookup);
        if (a.isError)
            return a;
        Value b = evaluate(e.args[1], lookup);
        if (b.isError)
            return b;
        return compare(e.op, a, b);
    }
    }
}

/// The `&` text form of a non-error value.
private string textForm(const Value v) @safe
{
    return v.isText ? v.text : v.toString;
}

private Value compare(BinaryOp op, Value a, Value b) pure @safe
{
    if (a.isEmpty && b.isEmpty)
    {
        a = Value.makeNumber(0);
        b = Value.makeNumber(0);
    }
    else if (a.isEmpty)
        a = b.isNumber ? Value.makeNumber(0) : Value.makeText("");
    else if (b.isEmpty)
        b = a.isNumber ? Value.makeNumber(0) : Value.makeText("");

    int order; // sign of a <=> b
    if (a.isNumber != b.isNumber)
    {
        // a number against a string: never converted
        if (op == BinaryOp.eq)
            return Value.makeNumber(0);
        if (op == BinaryOp.ne)
            return Value.makeNumber(1);
        return err(ErrorCode.value);
    }
    if (a.isNumber)
        order = a.number < b.number ? -1 : (a.number > b.number ? 1 : 0);
    else
    {
        import std.algorithm.comparison : cmp;
        import std.string : representation;
        order = cmp(a.text.representation, b.text.representation); // UTF-8 bytes == code points
    }
    bool r;
    final switch (op)
    {
    case BinaryOp.eq: r = order == 0; break;
    case BinaryOp.ne: r = order != 0; break;
    case BinaryOp.lt: r = order < 0; break;
    case BinaryOp.gt: r = order > 0; break;
    case BinaryOp.le: r = order <= 0; break;
    case BinaryOp.ge: r = order >= 0; break;
    case BinaryOp.add, BinaryOp.sub, BinaryOp.mul, BinaryOp.div, BinaryOp.concat:
        assert(0);
    }
    return Value.makeNumber(r ? 1 : 0);
}

private Value evalAggregate(const Expr e, scope CellLookup lookup) @safe
{
    size_t count;
    double sum = 0, lo = 0, hi = 0;

    // Adds one collected number, in order.
    void collect(double x) @safe
    {
        if (count == 0)
            lo = hi = x;
        else
        {
            if (x < lo) lo = x;
            if (x > hi) hi = x;
        }
        sum += x;
        count++;
    }

    foreach (arg; e.args)
    {
        if (arg.kind == ExprKind.range)
        {
            foreach (key; rangeKeys(arg.cell, arg.cellEnd))
            {
                const v = lookup(key);
                if (v.isError)
                    return v;
                if (v.isNumber)
                    collect(v.number);
            }
        }
        else
        {
            const v = evaluate(arg, lookup);
            if (v.isError)
                return v;
            if (v.isText)
                return err(ErrorCode.value);
            if (v.isNumber)
                collect(v.number);
        }
    }

    final switch (e.fn)
    {
    case Aggregate.count:
        return Value.makeNumber(cast(double) count);
    case Aggregate.sum:
        return isFinite(sum) ? Value.makeNumber(sum) : err(ErrorCode.value);
    case Aggregate.min:
        return Value.makeNumber(lo);
    case Aggregate.max:
        return Value.makeNumber(hi);
    case Aggregate.avg:
        if (count == 0)
            return err(ErrorCode.divZero);
        if (!isFinite(sum))
            return err(ErrorCode.value);
        return Value.makeNumber(sum / count);
    }
}
