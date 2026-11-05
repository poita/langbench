/// Table storage.
module minisql.table;

import minisql.value;

/// A table: an ordered list of column names and rows in insertion order.
final class Table
{
    /// Lower-cased table name.
    string name;
    /// Lower-cased column names, in declaration order.
    string[] columns;
    /// Rows in insertion order; each row has one value per column.
    Value[][] rows;

    this(string name, string[] columns) pure nothrow @safe
    {
        this.name = name;
        this.columns = columns;
    }

    /// The index of a column, or -1 when there is no such column.
    int columnIndex(string column) const pure nothrow @nogc @safe
    {
        foreach (i, c; columns)
            if (c == column)
                return cast(int) i;
        return -1;
    }
}
