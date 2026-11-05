/// Formula evaluation against the stored values of the cells it reads.
module spreadsheet.eval;

import std.math : isFinite;

import spreadsheet.ast;
import spreadsheet.numfmt : formatNumber;
import spreadsheet.value;

/**
 * Evaluate `f` once.  `values` is indexed by cell handle and must already be
 * current for every cell `f` reads; cells are never evaluated on demand.
 * An empty result becomes the number 0.  Only the selected `IF` branch is
 * evaluated, and the first problem in evaluation order wins.
 */
Value evaluate(ref const Formula f, const(Value)[] values)
{
    if (f.invalid)
        return Value.error(Kind.badRef);
    auto ev = Evaluator(&f, values);
    Value v = ev.eval(f.root);
    return v.kind == Kind.empty ? Value.number(0) : v;
}

private:

struct Evaluator
{
    const(Formula)* f;
    const(Value)[] values;

    /// Coerce an arithmetic operand: false means `v` is the final result.
    static bool toNumber(ref Value v, out double d) @safe pure nothrow @nogc
    {
        switch (v.kind)
        {
        case Kind.number: d = v.num; return true;
        case Kind.empty: d = 0; return true;
        case Kind.text: v = Value.error(Kind.badValue); return false;
        default: return false;
        }
    }

    Value eval(uint n)
    {
        const node = &f.nodes[n];
        final switch (node.kind)
        {
        case NodeKind.number: return Value.number(node.num);
        case NodeKind.text: return Value.text(node.str);
        case NodeKind.cell: return values[node.a];
        case NodeKind.negate:
        {
            Value x = eval(node.a);
            double d;
            if (!toNumber(x, d))
                return x;
            return Value.number(-d);
        }
        case NodeKind.binary: return evalBinary(node);
        case NodeKind.conditional:
        {
            Value c = eval(node.a);
            double d;
            if (!toNumber(c, d))
                return c;
            return eval(d != 0 ? node.b : node.c);
        }
        case NodeKind.aggregate: return evalAggregate(node);
        }
    }

    Value evalBinary(const(Node)* node)
    {
        immutable op = cast(BinOp) node.op;
        Value x = eval(node.a);
        if (op >= BinOp.concat)
        {
            if (x.isError)
                return x;
            Value y = eval(node.b);
            if (y.isError)
                return y;
            return op == BinOp.concat ? concat(x, y) : compare(op, x, y);
        }
        double da, db;
        if (!toNumber(x, da))
            return x;
        Value y = eval(node.b);
        if (!toNumber(y, db))
            return y;
        double r;
        final switch (op)
        {
        case BinOp.add: r = da + db; break;
        case BinOp.sub: r = da - db; break;
        case BinOp.mul: r = da * db; break;
        case BinOp.div:
            if (db == 0)
                return Value.error(Kind.divZero);
            r = da / db;
            break;
        case BinOp.concat, BinOp.eq, BinOp.ne, BinOp.lt, BinOp.gt, BinOp.le, BinOp.ge:
            assert(0);
        }
        if (!isFinite(r))
            return Value.error(Kind.badValue);
        return Value.number(r);
    }

    static Value concat(ref const Value x, ref const Value y)
    {
        // Avoid allocating when one side contributes nothing.
        if (x.kind == Kind.empty && y.kind == Kind.text)
            return Value.text(y.str);
        if (y.kind == Kind.empty && x.kind == Kind.text)
            return Value.text(x.str);
        import std.array : appender;
        auto app = appender!string();
        x.display(app);
        y.display(app);
        return Value.text(app.data);
    }

    static Value compare(BinOp op, Value x, Value y)
    {
        if (x.kind == Kind.empty && y.kind == Kind.empty)
        {
            x = Value.number(0);
            y = Value.number(0);
        }
        else if (x.kind == Kind.empty)
            x = y.kind == Kind.number ? Value.number(0) : Value.text("");
        else if (y.kind == Kind.empty)
            y = x.kind == Kind.number ? Value.number(0) : Value.text("");

        int c; // sign of x <=> y
        if (x.kind != y.kind)
        {
            if (op == BinOp.eq)
                return Value.number(0);
            if (op == BinOp.ne)
                return Value.number(1);
            return Value.error(Kind.badValue);
        }
        if (x.kind == Kind.number)
            c = x.num < y.num ? -1 : (x.num > y.num ? 1 : 0);
        else
            c = x.str < y.str ? -1 : (x.str > y.str ? 1 : 0);

        bool r;
        final switch (op)
        {
        case BinOp.eq: r = c == 0; break;
        case BinOp.ne: r = c != 0; break;
        case BinOp.lt: r = c < 0; break;
        case BinOp.gt: r = c > 0; break;
        case BinOp.le: r = c <= 0; break;
        case BinOp.ge: r = c >= 0; break;
        case BinOp.add, BinOp.sub, BinOp.mul, BinOp.div, BinOp.concat: assert(0);
        }
        return Value.number(r ? 1 : 0);
    }

    Value evalAggregate(const(Node)* node)
    {
        immutable op = cast(AggOp) node.op;
        size_t count = 0;
        double sum = 0, lo = 0, hi = 0;

        void collect(double d)
        {
            if (count == 0)
                lo = hi = d;
            else
            {
                if (d < lo) lo = d;
                if (d > hi) hi = d;
            }
            sum += d;
            count++;
        }

        foreach (ref const arg; f.args[node.a .. node.a + node.b])
        {
            if (arg.isRange)
            {
                foreach (h; f.rangeCells[arg.cellsStart .. arg.cellsStart + arg.cellsLen])
                {
                    ref const v = values[h];
                    if (v.kind == Kind.number)
                        collect(v.num);
                    else if (v.isError)
                        return v;
                }
            }
            else
            {
                Value v = eval(arg.node);
                if (v.isError)
                    return v;
                if (v.kind == Kind.text)
                    return Value.error(Kind.badValue);
                if (v.kind == Kind.number)
                    collect(v.num);
            }
        }

        final switch (op)
        {
        case AggOp.count: return Value.number(count);
        case AggOp.min: return Value.number(count ? lo : 0);
        case AggOp.max: return Value.number(count ? hi : 0);
        case AggOp.sum:
            return isFinite(sum) ? Value.number(sum) : Value.error(Kind.badValue);
        case AggOp.avg:
            if (count == 0)
                return Value.error(Kind.divZero);
            immutable avg = sum / count;
            return isFinite(sum) && isFinite(avg) ? Value.number(avg) : Value.error(Kind.badValue);
        }
    }
}
