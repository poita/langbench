/// Query execution: runs a parsed `Query` against a database and formats the result.
module sqlitefile.engine;

import std.algorithm.sorting : sort;
import std.algorithm.iteration : uniq;
import core.exception : RangeError;
import sqlitefile.affinity;
import sqlitefile.btree;
import sqlitefile.catalog;
import sqlitefile.database;
import sqlitefile.ddl : equalsCI;
import sqlitefile.errors;
import sqlitefile.output;
import sqlitefile.query;
import sqlitefile.record;
import sqlitefile.value;

@safe:

/// Runs one query line and returns the bytes of its result file. Any failure
/// (a bad query or a damaged database) yields `error\n`.
immutable(ubyte)[] answer(Database db, Catalog cat, string line) @trusted
{
    OutBuf o;
    try
    {
        execute(db, cat, parseQuery(line), o);
        return o.data.idup;
    }
    catch (Exception)
    {
        return cast(immutable(ubyte)[]) "error\n";
    }
    catch (RangeError)
    {
        return cast(immutable(ubyte)[]) "error\n";
    }
}

/// Executes `q`, appending its output to `o`. Throws `SqliteFileException` on failure;
/// `o` may then hold partial output, which the caller must discard.
void execute(Database db, Catalog cat, in Query q, ref OutBuf o)
{
    final switch (q.kind)
    {
    case QueryKind.tables:
        return runTables(cat, o);
    case QueryKind.schema:
        return runSchema(cat, q, o);
    case QueryKind.count:
        return runCount(db, cat, q, o);
    case QueryKind.select:
        return runSelect(db, cat, q, o);
    case QueryKind.index:
        return runIndex(db, cat, q, o);
    }
}

private void runTables(Catalog cat, ref OutBuf o)
{
    string[] names;
    foreach (ref e; cat.entries)
    {
        if (e.type != "table")
            continue;
        if (e.name.length >= 7 && equalsCI(e.name[0 .. 7], "sqlite_"))
            continue;
        names ~= e.name;
    }
    names.sort();
    foreach (n; names)
    {
        o.put(n);
        o.put(cast(ubyte) '\n');
    }
}

private void runSchema(Catalog cat, in Query q, ref OutBuf o)
{
    foreach (ref e; cat.entries)
        if (e.hasSql && equalsCI(e.tblName, q.name))
        {
            o.put(e.sql);
            o.put(";\n");
        }
}

private Table requireTable(Catalog cat, string name)
{
    auto t = cat.table(name);
    if (t is null)
        throw new QueryException("no such table");
    return t;
}

private int requireColumn(Table t, string name)
{
    immutable c = t.resolve(name);
    if (c == -2)
        throw new QueryException("no such column");
    return c;
}

private void runCount(Database db, Catalog cat, in Query q, ref OutBuf o)
{
    auto t = requireTable(cat, q.name);
    appendInteger(o, cast(long) countRows(db, t.rootPage));
    o.put(cast(ubyte) '\n');
}

private struct PreparedCond
{
    int column;
    CmpOp op;
    Value literal;
}

private bool matches(in Value v, in PreparedCond c) pure nothrow @nogc
{
    final switch (c.op)
    {
    case CmpOp.is_:
        return (v.isNull || c.literal.isNull) ? (v.isNull && c.literal.isNull)
            : compareValues(v, c.literal) == 0;
    case CmpOp.isNot:
        return !((v.isNull || c.literal.isNull) ? (v.isNull && c.literal.isNull)
                : compareValues(v, c.literal) == 0);
    case CmpOp.eq, CmpOp.ne, CmpOp.lt, CmpOp.le, CmpOp.gt, CmpOp.ge:
        if (v.isNull || c.literal.isNull)
            return false;
        immutable r = compareValues(v, c.literal);
        switch (c.op)
        {
        case CmpOp.eq:
            return r == 0;
        case CmpOp.ne:
            return r != 0;
        case CmpOp.lt:
            return r < 0;
        case CmpOp.le:
            return r <= 0;
        case CmpOp.gt:
            return r > 0;
        default:
            return r >= 0;
        }
    }
}

/// Appends the selected columns of one row, TAB-separated, plus a newline.
private void formatRow(ref OutBuf o, Table t, in int[] cols, ref const RecordReader rr, long rowid)
{
    foreach (i, c; cols)
    {
        if (i)
            o.put(cast(ubyte) '\t');
        appendValue(o, t.columnValue(rr, c, rowid));
    }
    o.put(cast(ubyte) '\n');
}

private struct SortRow
{
    long rowid;
    Value key;
    size_t first; // index of this row's first value in the pool
}

private Value detach(Value v, bool stable) pure nothrow
{
    if (!stable && (v.kind == ValueKind.text || v.kind == ValueKind.blob))
        v.bytes = v.bytes.dup;
    return v;
}

private void runSelect(Database db, Catalog cat, in Query q, ref OutBuf o)
{
    auto t = requireTable(cat, q.name);
    int[] cols;
    if (q.star)
        foreach (i; 0 .. t.columns.length)
            cols ~= cast(int) i;
    else
        foreach (n; q.columns)
            cols ~= requireColumn(t, n);
    PreparedCond[] conds;
    foreach (ref c; q.where)
    {
        immutable col = requireColumn(t, c.column);
        conds ~= PreparedCond(col, c.op, applyAffinity(c.literal, t.affinityOfColumn(col)));
    }
    int orderCol = 0;
    if (q.hasOrder)
        orderCol = requireColumn(t, q.orderColumn);
    if (q.hasLimit && q.limit == 0)
        return;

    RecordReader rr;
    if (!q.hasOrder)
    {
        long matched = 0;
        walkTable(db, t.rootPage, (long rowid, const(ubyte)[] payload, bool stable) @safe {
            rr.parse(payload);
            foreach (ref c; conds)
                if (!matches(t.columnValue(rr, c.column, rowid), c))
                    return true;
            formatRow(o, t, cols, rr, rowid);
            matched++;
            return !(q.hasLimit && matched >= q.limit);
        });
        return;
    }

    SortRow[] rows;
    Value[] pool;
    walkTable(db, t.rootPage, (long rowid, const(ubyte)[] payload, bool stable) @safe {
        rr.parse(payload);
        foreach (ref c; conds)
            if (!matches(t.columnValue(rr, c.column, rowid), c))
                return true;
        rows ~= SortRow(rowid, detach(t.columnValue(rr, orderCol, rowid), stable), pool.length);
        foreach (c; cols)
            pool ~= detach(t.columnValue(rr, c, rowid), stable);
        return true;
    });
    immutable desc = q.descending;
    rows.sort!((a, b) {
        int c = compareValues(a.key, b.key);
        if (desc)
            c = -c;
        return c != 0 ? c < 0 : a.rowid < b.rowid;
    });
    size_t n = rows.length;
    if (q.hasLimit && cast(ulong) q.limit < n)
        n = cast(size_t) q.limit;
    foreach (ref r; rows[0 .. n])
    {
        foreach (i; 0 .. cols.length)
        {
            if (i)
                o.put(cast(ubyte) '\t');
            appendValue(o, pool[r.first + i]);
        }
        o.put(cast(ubyte) '\n');
    }
}

private void runIndex(Database db, Catalog cat, in Query q, ref OutBuf o)
{
    auto ix = cat.index(q.name);
    if (ix is null || ix.columns.length != 1)
        throw new QueryException("not a usable single-column index");
    auto t = requireTable(cat, ix.tableName);
    immutable col = requireColumn(t, ix.columns[0]);
    auto key = applyAffinity(q.literal, t.affinityOfColumn(col));
    if (key.isNull)
        return;
    auto rowids = indexFind(db, ix.rootPage, key);
    rowids.sort();
    int[] cols;
    foreach (i; 0 .. t.columns.length)
        cols ~= cast(int) i;
    RecordReader rr;
    foreach (rid; rowids.uniq)
        seekTable(db, t.rootPage, rid, (long rowid, const(ubyte)[] payload, bool stable) @safe {
            rr.parse(payload);
            formatRow(o, t, cols, rr, rowid);
            return true;
        });
}
