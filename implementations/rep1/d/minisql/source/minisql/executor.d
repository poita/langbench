/// Execution of bound statements. Binding has already checked everything, so
/// nothing here can fail.
module minisql.executor;

import std.algorithm.sorting : sort;
import minisql.ast : AggFn;
import minisql.eval;
import minisql.keytable;
import minisql.plan;
import minisql.result;
import minisql.table;
import minisql.value;

private alias RowSink = void delegate(const(Value)[] row0, const(Value)[] row1) @safe;

/// Streams the rows (or row pairs, in nested-loop order) that satisfy ON and
/// WHERE into `sink`.
private void scan(const BoundSelect p, scope RowSink sink) @safe
{
    EvalCtx ctx;
    if (p.slotCount < 2)
    {
        if (p.slotCount == 0)
        {
            if (allTrue(p.firstFilters, ctx))
                sink(null, null);
            return;
        }
        foreach (row; p.tables[0].rows)
        {
            ctx.row0 = row;
            if (allTrue(p.firstFilters, ctx))
                sink(row, null);
        }
        return;
    }

    // Two tables: filter each side by its own conjuncts first.
    const rowsA = p.tables[0].rows;
    const rowsB = p.tables[1].rows;
    immutable nk = p.joinKeys.length;

    if (nk == 0)
    {
        size_t[] passing;
        foreach (j, rb; rowsB)
        {
            ctx.row1 = rb;
            if (allTrue(p.secondFilters, ctx))
                passing ~= j;
        }
        foreach (ra; rowsA)
        {
            ctx.row0 = ra;
            if (!allTrue(p.firstFilters, ctx))
                continue;
            foreach (j; passing)
            {
                ctx.row1 = rowsB[j];
                if (allTrue(p.residual, ctx))
                    sink(ra, rowsB[j]);
            }
        }
        return;
    }

    // Hash join on the cross-table equalities; the table is built on the
    // second table and probed in first-table order.
    auto table = KeyTable(nk);
    size_t[] rowOfEntry;
    auto key = new Value[nk];
    foreach (j, rb; rowsB)
    {
        ctx.row1 = rb;
        if (!allTrue(p.secondFilters, ctx))
            continue;
        bool hasNull = false;
        foreach (k, ref kp; p.joinKeys)
        {
            key[k] = eval(kp.right, ctx);
            hasNull = hasNull || key[k].isNull;
        }
        if (hasNull)
            continue;
        table.add(KeyTable.hashKey(key), key);
        rowOfEntry ~= j;
    }
    foreach (ra; rowsA)
    {
        ctx.row0 = ra;
        if (!allTrue(p.firstFilters, ctx))
            continue;
        bool hasNull = false;
        foreach (k, ref kp; p.joinKeys)
        {
            key[k] = eval(kp.left, ctx);
            hasNull = hasNull || key[k].isNull;
        }
        if (hasNull)
            continue;
        immutable h = KeyTable.hashKey(key);
        for (int e = table.find(h, key); e >= 0; e = table.findNext(e, h, key))
        {
            auto rb = rowsB[rowOfEntry[e]];
            ctx.row1 = rb;
            if (allTrue(p.residual, ctx))
                sink(ra, rb);
        }
    }
}

/// Running state of one aggregate call for one group.
private struct Accumulator
{
    long count;
    long sum;
    Value best;
}

private void accumulate(ref Accumulator a, const ref AggSpec spec, const ref EvalCtx ctx) @safe
{
    if (spec.arg is null)
    {
        a.count++;
        return;
    }
    auto v = eval(spec.arg, ctx);
    if (v.isNull)
        return;
    a.count++;
    final switch (spec.fn)
    {
    case AggFn.count:
        break;
    case AggFn.sum:
    case AggFn.avg:
        a.sum += v.num;
        break;
    case AggFn.min:
        if (a.count == 1 || compareValues(v, a.best) < 0)
            a.best = v;
        break;
    case AggFn.max:
        if (a.count == 1 || compareValues(v, a.best) > 0)
            a.best = v;
        break;
    }
}

private Value finish(const ref Accumulator a, AggFn fn) pure nothrow @nogc @safe
{
    final switch (fn)
    {
    case AggFn.count:
        return Value.makeInt(a.count);
    case AggFn.sum:
        return a.count == 0 ? Value.makeNull() : Value.makeInt(a.sum);
    case AggFn.min:
    case AggFn.max:
        return a.count == 0 ? Value.makeNull() : a.best;
    case AggFn.avg:
        {
            if (a.count == 0)
                return Value.makeNull();
            // hundredths = round-half-away-from-zero(100 * sum / count)
            immutable neg = a.sum < 0;
            immutable ulong s = neg ? -cast(ulong) a.sum : cast(ulong) a.sum;
            immutable ulong c = cast(ulong) a.count;
            immutable ulong h = (200 * s + c) / (2 * c);
            return Value.makeReal(neg ? -cast(long) h : cast(long) h);
        }
    }
}

/// A group's first row (for grouping columns) and its accumulators.
private struct GroupState
{
    const(Value)[] row0, row1;
}

/// Executes a bound SELECT.
Result executeSelect(const BoundSelect p) @safe
{
    immutable nItems = p.items.length;
    immutable width = nItems + p.extraKeys.length;
    Value[] records; // width values per surviving row/group

    void emit(const ref EvalCtx ctx) @safe
    {
        immutable base = records.length;
        records.length = base + width;
        foreach (i, it; p.items)
            records[base + i] = eval(it, ctx);
        foreach (i, it; p.extraKeys)
            records[base + nItems + i] = eval(it, ctx);
    }

    if (!p.aggregate)
    {
        scan(p, (row0, row1) @safe {
            EvalCtx ctx;
            ctx.row0 = row0;
            ctx.row1 = row1;
            emit(ctx);
        });
    }
    else
    {
        immutable nAgg = p.aggs.length;
        immutable nGroupCols = p.groupCols.length;
        GroupState[] groups;
        Accumulator[] accs;
        auto table = KeyTable(nGroupCols);
        auto key = new Value[nGroupCols];

        if (nGroupCols == 0)
        {
            groups.length = 1;
            accs.length = nAgg;
        }
        scan(p, (row0, row1) @safe {
            size_t g = 0;
            if (nGroupCols > 0)
            {
                foreach (k, gc; p.groupCols)
                    key[k] = (gc.slot == 0 ? row0 : row1)[gc.col];
                immutable h = KeyTable.hashKey(key);
                int e = table.find(h, key);
                if (e < 0)
                {
                    e = table.add(h, key);
                    groups ~= GroupState(row0, row1);
                    accs.length += nAgg;
                }
                g = e;
            }
            else
            {
                if (groups[0].row0 is null && groups[0].row1 is null)
                    groups[0] = GroupState(row0, row1);
            }
            EvalCtx ctx;
            ctx.row0 = row0;
            ctx.row1 = row1;
            foreach (i, ref spec; p.aggs)
                accumulate(accs[g * nAgg + i], spec, ctx);
        });

        // Groups come out in ascending order of their grouping values.
        auto order = new size_t[groups.length];
        foreach (i, ref o; order)
            o = i;
        if (nGroupCols > 0)
        {
            order.sort!((x, y) {
                auto kx = table.keyOf(x);
                auto ky = table.keyOf(y);
                foreach (i; 0 .. nGroupCols)
                {
                    immutable c = compareValues(kx[i], ky[i]);
                    if (c != 0)
                        return c < 0;
                }
                return false;
            });
        }
        auto finished = new Value[nAgg];
        foreach (g; order)
        {
            foreach (i, ref spec; p.aggs)
                finished[i] = finish(accs[g * nAgg + i], spec.fn);
            EvalCtx ctx;
            ctx.row0 = groups[g].row0;
            ctx.row1 = groups[g].row1;
            ctx.aggs = finished;
            if (p.having !is null)
            {
                auto hv = eval(p.having, ctx);
                if (truth(hv) != 1)
                    continue;
            }
            emit(ctx);
        }
    }

    // ORDER BY: a stable sort (ties broken by the pre-sort position).
    immutable nRecords = width == 0 ? 0 : records.length / width;
    auto perm = new size_t[nRecords];
    foreach (i, ref o; perm)
        o = i;
    if (p.sortKeys.length > 0)
    {
        perm.sort!((x, y) {
            foreach (ref k; p.sortKeys)
            {
                immutable c = compareValues(records[x * width + k.field], records[y * width + k.field]);
                if (c != 0)
                    return k.desc ? c > 0 : c < 0;
            }
            return x < y;
        });
    }

    // LIMIT / OFFSET
    size_t from = 0, to = nRecords;
    if (p.hasLimit)
    {
        from = p.offset > nRecords ? nRecords : cast(size_t) p.offset;
        immutable room = nRecords - from;
        to = p.limit > room ? nRecords : from + cast(size_t) p.limit;
    }

    Result r;
    r.isQuery = true;
    r.width = nItems;
    r.rowCount = to - from;
    r.cells = new Value[r.rowCount * nItems];
    foreach (i; from .. to)
    {
        immutable src = perm[i] * width;
        r.cells[(i - from) * nItems .. (i - from + 1) * nItems] = records[src .. src + nItems];
    }
    return r;
}

/// Executes a bound INSERT: every row is evaluated before any is appended.
void executeInsert(BoundInsert p) @safe
{
    EvalCtx ctx;
    Value[][] fresh;
    foreach (row; p.rows)
    {
        auto vals = new Value[row.length];
        foreach (i, e; row)
            vals[i] = eval(e, ctx);
        fresh ~= vals;
    }
    p.table.rows ~= fresh;
}

/// Executes a bound DELETE with a stable in-place compaction.
void executeDelete(BoundDelete p) @safe
{
    auto rows = p.table.rows;
    size_t w = 0;
    EvalCtx ctx;
    foreach (row; rows)
    {
        ctx.row0 = row;
        if (!allTrue(p.filters, ctx))
            rows[w++] = row;
    }
    p.table.rows = rows[0 .. w];
}

/// Executes a bound UPDATE. Right-hand sides see the row's old values.
void executeUpdate(BoundUpdate p) @safe
{
    auto tmp = new Value[p.values.length];
    EvalCtx ctx;
    foreach (row; p.table.rows)
    {
        ctx.row0 = row;
        if (!allTrue(p.filters, ctx))
            continue;
        foreach (i, e; p.values)
            tmp[i] = eval(e, ctx);
        foreach (i, c; p.columns)
            row[c] = tmp[i];
    }
}
