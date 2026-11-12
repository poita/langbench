/**
 * Execution of SELECT statements.
 *
 * The pipeline follows SPEC.md: FROM (with a hash join where the WHERE/ON
 * conjuncts allow one), WHERE, grouping, HAVING, the select list, one stable
 * ORDER BY sort, and LIMIT/OFFSET. Every statement scans its tables in full.
 */
module minisql.select;

import std.algorithm : sort, SwapStrategy;
import std.array : appender, Appender;

import minisql.ast;
import minisql.binder;
import minisql.errors;
import minisql.expr;
import minisql.table;
import minisql.value;

/// Executes the SELECT `s` over `tables` (keyed by lower-case name).
Value[][] executeSelect(Table[string] tables, Stmt s) @safe
{
    // --- sources ---
    Source[] sources;
    foreach (ref r; s.from)
    {
        auto t = r.name in tables;
        if (t is null)
            fail("no such table");
        immutable eff = r.effectiveName;
        foreach (o; sources)
            if (o.name == eff)
                fail("duplicate table name in FROM");
        sources ~= Source(eff, *t);
    }

    bool aggregateQuery = s.groupBy.length > 0 || containsAggregate(s.having);
    foreach (ref it; s.items)
        aggregateQuery |= containsAggregate(it.expr);
    foreach (ref t; s.orderBy)
        aggregateQuery |= containsAggregate(t.expr);

    // --- WHERE / ON ---
    auto whereBinder = new Binder(sources);
    BExpr[] conjuncts;
    if (s.joinOn !is null)
        splitConjuncts(whereBinder.bind(s.joinOn), conjuncts);
    if (s.where !is null)
        splitConjuncts(whereBinder.bind(s.where), conjuncts);

    // --- the rest is bound in aggregate mode where needed ---
    auto binder = new Binder(sources);
    binder.allowAggregates = true;
    binder.aggregateQuery = aggregateQuery;

    foreach (ref g; s.groupBy)
        binder.groupColumns ~= binder.resolve(g.qualifier, g.name);

    BExpr[] outputs;
    string[] aliases; // parallel to outputs; empty for columns without alias
    foreach (ref it; s.items)
    {
        if (it.star)
        {
            if (sources.length == 0)
                fail("* requires a FROM clause");
            foreach (slot, src; sources)
                foreach (c; 0 .. src.table.columns.length)
                {
                    immutable rc = ResolvedColumn(cast(int) slot, cast(int) c);
                    if (aggregateQuery)
                    {
                        bool grouped = false;
                        foreach (g; binder.groupColumns)
                            grouped |= g == rc;
                        if (!grouped)
                            fail("column is not grouped");
                    }
                    outputs ~= Binder.columnExpr(rc);
                    aliases ~= "";
                }
        }
        else
        {
            outputs ~= binder.bind(it.expr);
            aliases ~= it.alias_;
        }
    }

    BExpr having;
    if (s.having !is null)
        having = binder.bind(s.having);

    // Each ORDER BY term is either an output column or an expression.
    struct SortKey
    {
        ptrdiff_t outputColumn = -1;
        BExpr expr;
        bool descending;
    }

    SortKey[] sortKeys;
    foreach (ref t; s.orderBy)
    {
        SortKey k;
        k.descending = t.descending;
        auto e = t.expr;
        if (e.kind == ExprKind.column && e.qualifier.length == 0)
        {
            foreach (i, a; aliases)
                if (a.length && a == e.name)
                {
                    k.outputColumn = i;
                    break;
                }
        }
        if (k.outputColumn < 0 && e.kind == ExprKind.literal && e.value.kind == ValueKind.integer)
        {
            if (e.value.num < 1 || e.value.num > outputs.length)
                fail("ORDER BY position out of range");
            k.outputColumn = cast(ptrdiff_t) e.value.num - 1;
        }
        if (k.outputColumn < 0)
            k.expr = binder.bind(e);
        sortKeys ~= k;
    }

    // --- FROM / WHERE / ON ---
    Candidate[] candidates = scan(sources, conjuncts);

    // --- grouping, HAVING, select list, sort keys ---
    struct OutRow
    {
        Value[] values;
        Value[] keys;
    }

    auto rows = appender!(OutRow[]);

    void emit(ref const EvalContext ctx)
    {
        OutRow r;
        r.values = new Value[outputs.length];
        foreach (i, o; outputs)
            r.values[i] = evaluate(o, ctx);
        if (sortKeys.length)
        {
            r.keys = new Value[sortKeys.length];
            foreach (i, k; sortKeys)
                r.keys[i] = k.outputColumn >= 0 ? r.values[k.outputColumn] : evaluate(k.expr, ctx);
        }
        rows.put(r);
    }

    if (!aggregateQuery)
    {
        EvalContext ctx;
        foreach (ref c; candidates)
        {
            ctx.rows[0] = c.a;
            ctx.rows[1] = c.b;
            emit(ctx);
        }
    }
    else
    {
        foreach (ref g; makeGroups(candidates, binder.groupColumns, s.groupBy.length > 0))
        {
            EvalContext ctx;
            if (g.members.length)
            {
                ctx.rows[0] = g.members[0].a;
                ctx.rows[1] = g.members[0].b;
            }
            auto results = new Value[binder.aggregates.length];
            foreach (i, ref spec; binder.aggregates)
                results[i] = computeAggregate(spec, g.members);
            ctx.aggregates = results;
            if (having !is null && !isTrue(having, ctx))
                continue;
            emit(ctx);
        }
    }

    // --- ORDER BY: one stable sort of all rows ---
    if (sortKeys.length)
    {
        bool less(ref const OutRow x, ref const OutRow y)
        {
            foreach (i, k; sortKeys)
            {
                int c = compareValues(x.keys[i], y.keys[i]);
                if (k.descending)
                    c = -c;
                if (c != 0)
                    return c < 0;
            }
            return false;
        }

        rows[].sort!(less, SwapStrategy.stable);
    }

    // --- LIMIT / OFFSET ---
    auto all = rows[];
    size_t from = 0, to = all.length;
    if (s.hasLimit)
    {
        from = s.offset > all.length ? all.length : cast(size_t) s.offset;
        immutable remaining = all.length - from;
        to = from + (s.limit > remaining ? remaining : cast(size_t) s.limit);
    }
    auto result = new Value[][to - from];
    foreach (i; from .. to)
        result[i - from] = all[i].values;
    return result;
}

/// One row of the FROM product: a row of each FROM table (empty where unused).
private struct Candidate
{
    const(Value)[] a;
    const(Value)[] b;
}

private void encodeValue(ref Appender!(char[]) buf, in Value v) @safe
{
    final switch (v.kind)
    {
    case ValueKind.null_:
        buf.put('n');
        break;
    case ValueKind.integer:
    case ValueKind.real_:
        buf.put('i');
        foreach (shift; 0 .. 8)
            buf.put(cast(char)((cast(ulong) v.num >> (8 * shift)) & 0xFF));
        break;
    case ValueKind.text:
        buf.put('t');
        foreach (shift; 0 .. 4)
            buf.put(cast(char)((v.str.length >> (8 * shift)) & 0xFF));
        buf.put(v.str);
        break;
    }
}

/// Produces the candidate rows that pass all `conjuncts`, in nested-loop order.
private Candidate[] scan(Source[] sources, BExpr[] conjuncts) @trusted
{
    auto result = appender!(Candidate[]);
    EvalContext ctx;
    static immutable const(Value)[] none = [];

    bool passes(BExpr[] conds)
    {
        foreach (c; conds)
            if (!isTrue(c, ctx))
                return false;
        return true;
    }

    if (sources.length < 2)
    {
        const(Value[])[] rows = sources.length ? sources[0].table.rows : [none];
        foreach (ref row; rows)
        {
            ctx.rows[0] = row;
            if (passes(conjuncts))
                result.put(Candidate(row, none));
        }
        return result[];
    }

    // Two tables. Conjuncts over table 0 only (or no table) filter it first,
    // those over table 1 only filter that, the rest are applied to pairs.
    BExpr[] onlyA, onlyB, cross;
    foreach (c; conjuncts)
    {
        immutable m = tableMask(c);
        if (m <= 1)
            onlyA ~= c;
        else if (m == 2)
            onlyB ~= c;
        else
            cross ~= c;
    }

    const(Value)[][] aRows, bRows;
    foreach (ref row; sources[0].table.rows)
    {
        ctx.rows[0] = row;
        if (passes(onlyA))
            aRows ~= row;
    }
    foreach (ref row; sources[1].table.rows)
    {
        ctx.rows[1] = row;
        if (passes(onlyB))
            bRows ~= row;
    }
    ctx.rows[0] = none;
    ctx.rows[1] = none;

    // Cross-table equalities become one composite hash key.
    BExpr[] keyA, keyB, residual;
    foreach (c; cross)
    {
        if (c.kind == BKind.binary && c.op == BinOp.eq)
        {
            immutable ml = tableMask(c.lhs), mr = tableMask(c.rhs);
            if (ml == 1 && mr == 2)
            {
                keyA ~= c.lhs;
                keyB ~= c.rhs;
                continue;
            }
            if (ml == 2 && mr == 1)
            {
                keyA ~= c.rhs;
                keyB ~= c.lhs;
                continue;
            }
        }
        residual ~= c;
    }

    if (keyA.length == 0)
    {
        foreach (ra; aRows)
        {
            ctx.rows[0] = ra;
            foreach (rb; bRows)
            {
                ctx.rows[1] = rb;
                if (passes(residual))
                    result.put(Candidate(ra, rb));
            }
        }
        return result[];
    }

    // Returns false if any key part is NULL (NULL never equals anything).
    auto keyBuf = appender!(char[]);
    bool makeKey(BExpr[] exprs)
    {
        keyBuf.clear();
        foreach (e; exprs)
        {
            immutable v = evaluate(e, ctx);
            if (v.isNull)
                return false;
            encodeValue(keyBuf, v);
        }
        return true;
    }

    size_t[][string] buckets;
    foreach (j, rb; bRows)
    {
        ctx.rows[1] = rb;
        if (!makeKey(keyB))
            continue;
        auto k = cast(string) keyBuf[];
        if (auto p = k in buckets)
            *p ~= j;
        else
            buckets[k.idup] = [j];
    }
    ctx.rows[1] = none;
    foreach (ra; aRows)
    {
        ctx.rows[0] = ra;
        if (!makeKey(keyA))
            continue;
        auto p = (cast(string) keyBuf[]) in buckets;
        if (p is null)
            continue;
        foreach (j; *p)
        {
            ctx.rows[1] = bRows[j];
            if (passes(residual))
                result.put(Candidate(ra, bRows[j]));
        }
    }
    return result[];
}

private struct Group
{
    Value[] key;
    Candidate[] members;
}

/// Partitions `candidates` into groups ordered by their grouping values.
/// Without GROUP BY there is always exactly one group.
private Group[] makeGroups(Candidate[] candidates, ResolvedColumn[] groupColumns, bool hasGroupBy) @trusted
{
    if (!hasGroupBy)
        return [Group(null, candidates)];

    Group[] groups;
    size_t[string] index;
    auto buf = appender!(char[]);
    foreach (ref c; candidates)
    {
        buf.clear();
        auto key = new Value[groupColumns.length];
        foreach (i, gc; groupColumns)
        {
            key[i] = (gc.slot == 0 ? c.a : c.b)[gc.column];
            encodeValue(buf, key[i]);
        }
        auto k = cast(string) buf[];
        if (auto p = k in index)
            groups[*p].members ~= c;
        else
        {
            index[k.idup] = groups.length;
            groups ~= Group(key, [c]);
        }
    }
    groups.sort!((x, y) {
        foreach (i; 0 .. x.key.length)
        {
            immutable c = compareValues(x.key[i], y.key[i]);
            if (c != 0)
                return c < 0;
        }
        return false;
    });
    return groups;
}

/// Evaluates one aggregate over the rows of a group.
private Value computeAggregate(ref const AggSpec spec, Candidate[] members) @safe
{
    if (spec.func == AggFunc.count && spec.arg is null)
        return Value.integer(cast(long) members.length);

    EvalContext ctx;
    long count = 0, sum = 0;
    Value best;
    foreach (ref m; members)
    {
        ctx.rows[0] = m.a;
        ctx.rows[1] = m.b;
        immutable v = evaluate(spec.arg, ctx);
        if (v.isNull)
            continue;
        ++count;
        final switch (spec.func)
        {
        case AggFunc.count:
            break;
        case AggFunc.sum:
        case AggFunc.avg:
            if (v.kind == ValueKind.integer)
                sum += v.num;
            break;
        case AggFunc.min:
            if (count == 1 || compareValues(v, best) < 0)
                best = v;
            break;
        case AggFunc.max:
            if (count == 1 || compareValues(v, best) > 0)
                best = v;
            break;
        }
    }
    final switch (spec.func)
    {
    case AggFunc.count:
        return Value.integer(count);
    case AggFunc.sum:
        return count ? Value.integer(sum) : Value.null_;
    case AggFunc.min:
    case AggFunc.max:
        return count ? best : Value.null_;
    case AggFunc.avg:
        if (count == 0)
            return Value.null_;
        // s / c rounded half away from zero to hundredths, in integers.
        immutable mag = sum < 0 ? -sum : sum;
        immutable h = (200 * mag + count) / (2 * count);
        return Value.real_(sum < 0 ? -h : h);
    }
}
