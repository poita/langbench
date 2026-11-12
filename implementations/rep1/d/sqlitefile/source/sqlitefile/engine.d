/// Query execution: resolves a parsed `Query` against the catalog and
/// evaluates it by walking B-trees (SPEC Part 4).
module sqlitefile.engine;

import std.algorithm.sorting : sort;
import std.format : format;
import sqlitefile.affinity;
import sqlitefile.btree;
import sqlitefile.database;
import sqlitefile.errors;
import sqlitefile.query;
import sqlitefile.record;
import sqlitefile.render;
import sqlitefile.schema;
import sqlitefile.value;

@safe:

/// Executes query lines against one database.
///
/// The catalog is read once on construction; nothing else is cached between
/// queries.
final class Engine
{
    private const Database db_;
    private Catalog catalog_;

    /// Reads the schema of `db`.
    this(const Database db)
    {
        db_ = db;
        catalog_ = new Catalog(db);
    }

    /// The parsed schema.
    inout(Catalog) catalog() inout pure nothrow @nogc
    {
        return catalog_;
    }

    /// Runs one query line and returns the bytes of its result file.
    /// Throws a `SqliteFileException` if the query fails.
    const(ubyte)[] execute(string line)
    {
        OutBuf o;
        execute(parseQuery(line), o);
        return o.data;
    }

    /// Like `execute`, but returns the single line `error\n` on failure.
    const(ubyte)[] executeOrError(string line) nothrow
    {
        try
            return execute(line);
        catch (Exception)
            return cast(const(ubyte)[]) "error\n";
    }

    /// Runs a parsed query, appending its output to `o`.
    void execute(in Query q, ref OutBuf o)
    {
        final switch (q.kind)
        {
        case QueryKind.tables:
            foreach (n; catalog_.userTableNames)
            {
                appendText(o, n);
                o.put(cast(ubyte) '\n');
            }
            break;
        case QueryKind.schema:
            foreach (sql; catalog_.schemaFor(q.name))
            {
                appendText(o, sql);
                appendText(o, ";\n");
            }
            break;
        case QueryKind.count:
            const t = catalog_.findTable(q.name);
            if (t is null)
                throw new QueryException("no such table");
            appendInt(o, cast(long) countTable(db_, t.rootPage));
            o.put(cast(ubyte) '\n');
            break;
        case QueryKind.select:
            select(q, o);
            break;
        case QueryKind.index:
            indexLookup(q, o);
            break;
        }
    }

    // --- SELECT ---------------------------------------------------------------

    private static struct BoundCondition
    {
        ptrdiff_t column; // -1: the rowid
        CompareOp op;
        Value literal; // affinity already applied
    }

    private static struct Row
    {
        long rowid;
        Value key;
        Value[] values;
    }

    private static const(Table)* requireColumns(const(Table)* t)
    {
        if (t is null || !t.columnsKnown)
            throw new QueryException("no such table");
        return t;
    }

    private static ptrdiff_t resolveColumn(in Table t, string name)
    {
        const i = t.columnIndex(name);
        if (i >= 0)
            return i;
        if (asciiEqualFoldRowid(name))
            return -1;
        throw new QueryException("no such column");
    }

    private static bool asciiEqualFoldRowid(string s) pure nothrow @nogc
    {
        import sqlitefile.ddl : asciiEqualFold;

        return asciiEqualFold(s, "ROWID");
    }

    private static Affinity affinityOfColumn(in Table t, ptrdiff_t col)
    {
        return col < 0 ? Affinity.integer : t.columns[col].affinity;
    }

    private static bool matches(in BoundCondition c, in Value v)
    {
        final switch (c.op)
        {
        case CompareOp.is_:
            return compare(v, c.literal) == 0;
        case CompareOp.isNot:
            return compare(v, c.literal) != 0;
        case CompareOp.eq:
        case CompareOp.ne:
        case CompareOp.lt:
        case CompareOp.le:
        case CompareOp.gt:
        case CompareOp.ge:
            if (v.isNull || c.literal.isNull)
                return false;
            const r = compare(v, c.literal);
            switch (c.op)
            {
            case CompareOp.eq:
                return r == 0;
            case CompareOp.ne:
                return r != 0;
            case CompareOp.lt:
                return r < 0;
            case CompareOp.le:
                return r <= 0;
            case CompareOp.gt:
                return r > 0;
            default:
                return r >= 0;
            }
        }
    }

    private void select(in Query q, ref OutBuf o)
    {
        const t = requireColumns(catalog_.findTable(q.name));
        const ncols = t.columns.length;

        ptrdiff_t[] selected;
        if (q.star)
            foreach (i; 0 .. ncols)
                selected ~= cast(ptrdiff_t) i;
        else
            foreach (name; q.columns)
                selected ~= resolveColumn(*t, name);

        BoundCondition[] conds;
        foreach (c; q.where)
        {
            const col = resolveColumn(*t, c.column);
            conds ~= BoundCondition(col, c.op, applyAffinity(c.literal, affinityOfColumn(*t, col)));
        }
        const orderCol = q.hasOrder ? resolveColumn(*t, q.orderColumn) : 0;
        if (q.hasLimit && q.limit == 0)
            return;

        auto buf = new Value[ncols];
        Row[] kept;
        long emitted = 0;

        walkTable(db_, t.rootPage, (long rowid, const(ubyte)[] payload) @safe {
            t.decodeRow(rowid, payload, buf);
            foreach (ref c; conds)
                if (!matches(c, c.column < 0 ? Value.fromInt(rowid) : buf[c.column]))
                    return true;
            if (q.hasOrder)
            {
                Row r;
                r.rowid = rowid;
                r.key = orderCol < 0 ? Value.fromInt(rowid) : buf[orderCol];
                r.values = project(buf, rowid, selected);
                kept ~= r;
                return true;
            }
            writeRow(o, project(buf, rowid, selected));
            emitted++;
            return !(q.hasLimit && emitted >= q.limit);
        });

        if (q.hasOrder)
        {
            const desc = q.orderDesc;
            kept.sort!((a, b) {
                const c = compare(a.key, b.key);
                if (c != 0)
                    return desc ? c > 0 : c < 0;
                return a.rowid < b.rowid;
            });
            if (q.hasLimit && kept.length > q.limit)
                kept = kept[0 .. cast(size_t) q.limit];
            foreach (ref r; kept)
                writeRow(o, r.values);
        }
    }

    private static Value[] project(const Value[] row, long rowid, const ptrdiff_t[] selected)
    {
        auto vals = new Value[selected.length];
        foreach (i, c; selected)
            vals[i] = c < 0 ? Value.fromInt(rowid) : row[c];
        return vals;
    }

    private static void writeRow(ref OutBuf o, const Value[] vals)
    {
        foreach (i, ref v; vals)
        {
            if (i)
                o.put(cast(ubyte) '\t');
            appendValue(o, v);
        }
        o.put(cast(ubyte) '\n');
    }

    // --- INDEX ----------------------------------------------------------------

    private void indexLookup(in Query q, ref OutBuf o)
    {
        const ix = catalog_.findIndex(q.name);
        if (ix is null || ix.columns.length != 1)
            throw new QueryException("no such single-column index");
        const t = requireColumns(catalog_.findTable(ix.table));
        const col = t.columnIndex(ix.columns[0]);
        if (col < 0)
            throw new QueryException("index column not found in table");

        const key = applyAffinity(q.literal, t.columns[col].affinity);
        if (key.isNull)
            return; // NULL matches nothing

        long[] rowids;
        Value[1] first;
        searchIndex(db_, ix.rootPage, (const(ubyte)[] payload) @safe {
            decodeRecord(payload, first[]);
            return compare(first[0], key);
        }, (const(ubyte)[] payload) @safe {
            const vals = decodeAll(payload);
            if (vals.length < 2 || vals[$ - 1].type != ValueType.integer)
                throw new FormatException("index entry without a rowid");
            rowids ~= vals[$ - 1].i;
            return true;
        });
        rowids.sort();

        auto buf = new Value[t.columns.length];
        long prev;
        bool havePrev = false;
        foreach (rowid; rowids)
        {
            if (havePrev && rowid == prev)
                continue;
            prev = rowid;
            havePrev = true;
            const(ubyte)[] payload;
            if (!findTableRow(db_, t.rootPage, rowid, payload))
                continue;
            t.decodeRow(rowid, payload, buf);
            writeRow(o, buf);
        }
    }
}

// --- tests (fixtures in tests/data, generated with the sqlite3 shell) --------

version (unittest)
{
    import std.conv : to;
    import std.file : exists, readText;
    import std.string : splitLines;

    private string runOne(Engine e, string q) @trusted
    {
        return cast(string) e.execute(q).idup;
    }
}

unittest
{
    // The worked example of SPEC.md.
    assert(exists("tests/data/mini.sqlite"), "run dub test from the package root");
    auto engine = new Engine(Database.open("tests/data/mini.sqlite"));
    auto queries = readText("tests/data/mini.queries.txt").splitLines;
    foreach (n, q; queries)
    {
        const want = readText("tests/data/mini.expected/" ~ format("%03d", n + 1) ~ ".txt");
        auto got = cast(string) engine.executeOrError(q).idup;
        assert(got == want, q ~ "\n--- got\n" ~ got ~ "--- want\n" ~ want);
    }
}

unittest
{
    import std.exception : assertThrown;

    assert(exists("tests/data/mini.sqlite"), "run dub test from the package root");
    auto e = new Engine(Database.open("tests/data/mini.sqlite"));
    assert(runOne(e, "SELECT name FROM people WHERE age >= '36' ORDER BY name DESC") == "Grace\nAda\n");
    assert(runOne(e, "SELECT id FROM people WHERE id = 6.0") == "6\n");
    assert(runOne(e, "SELECT name FROM people WHERE rowid < 3 LIMIT 0") == "");
    assert(runOne(e, "SELECT name FROM people WHERE name = 7") == "");
    assert(runOne(e, "INDEX people_age NULL") == "");
    assert(runOne(e, "INDEX PEOPLE_AGE '36'") == "1\tAda\t36\t1.65\t000102\n");
    assert(runOne(e, ".schema people_age") == "");
    assert(runOne(e, ".schema nosuch") == "");
    assertThrown!QueryException(e.execute("SELECT * FROM sqlite_schema"));
    assertThrown!QueryException(e.execute("SELECT * FROM people_age"));
    assertThrown!QueryException(e.execute("SELECT oid FROM people"));
    assertThrown!QueryException(e.execute("INDEX people 1"));
    assertThrown!QueryException(e.execute(".SCHEMA people"));
    assert(e.executeOrError("COUNT nope") == cast(const(ubyte)[]) "error\n");
}

unittest
{
    // 512-byte pages, interior B-tree pages, overflow chains, two indexes.
    assert(exists("tests/data/big.sqlite"), "run dub test from the package root");
    auto e = new Engine(Database.open("tests/data/big.sqlite"));
    assert(runOne(e, "COUNT t") == "1350\n");
    assert(runOne(e, "SELECT id FROM t ORDER BY score DESC LIMIT 2") == "1500\n1499\n");
    assert(runOne(e, "SELECT id,label,score FROM t WHERE label = 'label-1234'")
            == "1234\tlabel-1234\t308.5\n");
    assert(runOne(e, "INDEX t_label 'label-1234'").length > 0);
    auto grp = runOne(e, "INDEX t_grp 3").splitLines;
    assert(grp.length == 192);
    assert(runOne(e, "SELECT * FROM t WHERE grp = 3").splitLines == grp);
    auto big = runOne(e, "SELECT payload FROM t WHERE id = 100");
    assert(big.length == 6001); // 3000 bytes in hex plus newline, via overflow pages
    assert(runOne(e, "SELECT id FROM t WHERE id = 13") == "");
    assert(runOne(e, "SELECT id FROM t LIMIT 3") == "1\n2\n4\n");
}
