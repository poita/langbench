/// The catalog: `sqlite_schema` read once and parsed into tables and indexes.
module sqlitefile.schema;

import std.algorithm.sorting : sort;
import sqlitefile.affinity;
import sqlitefile.btree;
import sqlitefile.database;
import sqlitefile.ddl;
import sqlitefile.errors;
import sqlitefile.record;
import sqlitefile.value;

@safe:

/// One row of `sqlite_schema`.
struct SchemaRow
{
    string type; /// `table`, `index`, `view` or `trigger`
    string name;
    string tblName;
    long rootPage;
    string sql; /// empty when NULL
    bool hasSql;
}

/// A column of a table.
struct Column
{
    string name;
    Affinity affinity;
    bool isRowidAlias;
}

/// A table known from the schema.
struct Table
{
    string name;
    uint rootPage;
    Column[] columns;
    /// False if the `CREATE TABLE` could not be parsed; such a table can only
    /// be counted.
    bool columnsKnown;

    /// Index of the column called `name` (ASCII case-insensitive) or -1.
    ptrdiff_t columnIndex(const(char)[] colName) const pure
    {
        foreach (i, ref c; columns)
            if (asciiEqualFold(c.name, colName))
                return i;
        return -1;
    }

    /// Decodes a stored row into `dst` (one slot per column): missing trailing
    /// columns become NULL, the rowid alias is replaced by `rowid`, and
    /// integers in REAL-affinity columns become REAL (SPEC §2.4).
    void decodeRow(long rowid, const(ubyte)[] payload, Value[] dst) const
    {
        decodeRecord(payload, dst[0 .. columns.length]);
        foreach (i, ref c; columns)
        {
            if (c.isRowidAlias)
                dst[i] = Value.fromInt(rowid);
            else if (c.affinity == Affinity.real_ && dst[i].type == ValueType.integer)
                dst[i] = Value.fromReal(cast(double) dst[i].i);
        }
    }
}

/// An index created by `CREATE INDEX`.
struct Index
{
    string name;
    string table;
    uint rootPage;
    string[] columns;
}

/// Everything the query engine needs to know about the database's schema.
final class Catalog
{
    /// All `sqlite_schema` rows in schema (rowid) order.
    SchemaRow[] rows;
    private Table[] tables_;
    private Index[] indexes_;

    /// Reads and parses `sqlite_schema` (the table rooted at page 1).
    this(const Database db)
    {
        walkTable(db, 1, (long rowid, const(ubyte)[] payload) @safe {
            Value[5] v;
            decodeRecord(payload, v[]);
            SchemaRow r;
            r.type = textOf(v[0]);
            r.name = textOf(v[1]);
            r.tblName = textOf(v[2]);
            r.rootPage = v[3].type == ValueType.integer ? v[3].i : 0;
            r.hasSql = v[4].type == ValueType.text;
            r.sql = r.hasSql ? v[4].toStringCopy : "";
            rows ~= r;
            return true;
        });
        foreach (ref r; rows)
        {
            if (r.type == "table")
            {
                Table t;
                t.name = r.name;
                t.rootPage = cast(uint) r.rootPage;
                if (r.hasSql)
                {
                    try
                    {
                        auto def = parseCreateTable(r.sql);
                        foreach (c; def.columns)
                            t.columns ~= Column(c.name, c.affinity, c.isRowidAlias);
                        t.columnsKnown = true;
                    }
                    catch (SchemaException)
                    {
                    }
                }
                tables_ ~= t;
            }
            else if (r.type == "index" && r.hasSql)
            {
                try
                {
                    auto def = parseCreateIndex(r.sql);
                    indexes_ ~= Index(r.name, r.tblName, cast(uint) r.rootPage, def.columns);
                }
                catch (SchemaException)
                {
                }
            }
        }
    }

    private static string textOf(in Value v) @safe
    {
        return v.type == ValueType.text ? v.toStringCopy : "";
    }

    /// Looks up a table by name (ASCII case-insensitive).
    const(Table)* findTable(const(char)[] name) const pure
    {
        foreach (k; 0 .. tables_.length)
            if (asciiEqualFold(tables_[k].name, name))
                return &tables_[k];
        return null;
    }

    /// Looks up an index created by `CREATE INDEX` by name.
    const(Index)* findIndex(const(char)[] name) const pure
    {
        foreach (k; 0 .. indexes_.length)
            if (asciiEqualFold(indexes_[k].name, name))
                return &indexes_[k];
        return null;
    }

    /// Names of user tables (not starting with `sqlite_`), sorted bytewise.
    string[] userTableNames() const pure
    {
        string[] names;
        foreach (ref r; rows)
        {
            if (r.type != "table")
                continue;
            if (r.name.length >= 7 && asciiEqualFold(r.name[0 .. 7], "SQLITE_"))
                continue;
            names ~= r.name;
        }
        names.sort();
        return names;
    }

    /// The `sql` of every row whose `tbl_name` is `table`, in schema order,
    /// skipping rows with NULL `sql`.
    string[] schemaFor(const(char)[] table) const pure
    {
        string[] result;
        foreach (ref r; rows)
            if (r.hasSql && asciiEqualFold(r.tblName, table))
                result ~= r.sql;
        return result;
    }
}
