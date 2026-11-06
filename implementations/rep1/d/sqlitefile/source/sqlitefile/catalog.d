/// The schema catalog: every `sqlite_schema` row plus parsed tables and indexes.
module sqlitefile.catalog;

import sqlitefile.affinity;
import sqlitefile.btree;
import sqlitefile.database;
import sqlitefile.ddl;
import sqlitefile.errors;
import sqlitefile.record;
import sqlitefile.value;

@safe:

/// Marker column number meaning "the rowid".
enum int rowidColumn = -1;

/// One row of `sqlite_schema`.
struct SchemaEntry
{
    long rowid;
    string type;
    string name;
    string tblName;
    long rootPage;
    string sql;
    bool hasSql; /// false when `sql` is NULL
}

/// A table described by its `CREATE TABLE` statement.
final class Table
{
    string name;
    Column[] columns;
    int rowidAlias = -1;
    uint rootPage;

    /// Resolves a column name (ASCII case-insensitive); `rowid` yields
    /// `rowidColumn` unless a real column has that name. Returns -2 if unknown.
    int resolve(const(char)[] colName) const pure nothrow @nogc
    {
        foreach (i, ref c; columns)
            if (equalsCI(c.name, colName))
                return cast(int) i;
        if (equalsCI(colName, "rowid"))
            return rowidColumn;
        return -2;
    }

    /// The affinity of column `col` (`rowidColumn` has INTEGER affinity).
    Affinity affinityOfColumn(int col) const pure nothrow @nogc
    {
        return col == rowidColumn ? Affinity.integer : columns[col].affinity;
    }

    /// Reads column `col` of a row whose record has been parsed into `rr`:
    /// substitutes the rowid for the alias column and widens integers stored
    /// in REAL-affinity columns (SPEC §2.2, §2.4).
    Value columnValue(ref const RecordReader rr, int col, long rowid) const pure
    {
        if (col == rowidColumn || col == rowidAlias)
            return Value.makeInt(rowid);
        auto v = rr.value(col);
        if (v.kind == ValueKind.integer && columns[col].affinity == Affinity.real_)
            return Value.makeReal(cast(double) v.i);
        return v;
    }
}

/// An index described by its `CREATE INDEX` statement.
final class Index
{
    string name;
    string tableName;
    string[] columns;
    uint rootPage;
}

/// ASCII lower-casing, used for case-insensitive name keys.
string asciiLower(string s) pure nothrow
{
    char[] r = new char[s.length];
    foreach (i, c; s)
        r[i] = (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
    return (() @trusted => cast(string) r)();
}

/// All schema objects of a database, read once.
final class Catalog
{
    /// Every `sqlite_schema` row in rowid (schema) order.
    SchemaEntry[] entries;
    private Table[string] tableMap;
    private Index[string] indexMap;

    /// Reads and parses `sqlite_schema`. Objects whose SQL cannot be parsed are skipped.
    static Catalog load(Database db)
    {
        auto cat = new Catalog;
        RecordReader rr;
        walkTable(db, 1, (long rowid, const(ubyte)[] payload, bool stable) @safe {
            rr.parse(payload);
            SchemaEntry e;
            e.rowid = rowid;
            e.type = textOf(rr.value(0));
            e.name = textOf(rr.value(1));
            e.tblName = textOf(rr.value(2));
            auto rp = rr.value(3);
            e.rootPage = rp.kind == ValueKind.integer ? rp.i : 0;
            auto sql = rr.value(4);
            e.hasSql = sql.kind == ValueKind.text;
            e.sql = textOf(sql);
            cat.entries ~= e;
            return true;
        });
        foreach (ref e; cat.entries)
        {
            try
            {
                if (e.type == "table" && e.hasSql)
                {
                    auto def = parseCreateTable(e.sql);
                    auto t = new Table;
                    t.name = e.name;
                    t.columns = def.columns;
                    t.rowidAlias = def.rowidAlias;
                    t.rootPage = cast(uint) e.rootPage;
                    cat.tableMap.require(asciiLower(e.name), t);
                }
                else if (e.type == "index" && e.hasSql)
                {
                    auto def = parseCreateIndex(e.sql);
                    auto ix = new Index;
                    ix.name = e.name;
                    ix.tableName = def.table;
                    ix.columns = def.columns;
                    ix.rootPage = cast(uint) e.rootPage;
                    cat.indexMap.require(asciiLower(e.name), ix);
                }
            }
            catch (FormatException)
            {
                // unparsable DDL: the object is simply unavailable to queries
            }
        }
        return cat;
    }

    /// Looks up a table by name (ASCII case-insensitive); null if there is none.
    Table table(string name)
    {
        auto p = asciiLower(name) in tableMap;
        return p ? *p : null;
    }

    /// Looks up a `CREATE INDEX` index by name; null if there is none.
    Index index(string name)
    {
        auto p = asciiLower(name) in indexMap;
        return p ? *p : null;
    }
}

private string textOf(in Value v) pure nothrow @trusted
{
    return v.kind == ValueKind.text ? cast(string) v.bytes.idup : "";
}
