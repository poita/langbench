/**
 * Tables: a column list and rows in insertion order.
 */
module minisql.table;

import minisql.value;

/// A table. Rows keep insertion order; UPDATE changes them in place.
final class Table
{
    /// The table's name, lower-cased.
    string name;
    /// Column names, lower-cased, in declaration order.
    string[] columns;
    /// The rows, each with one value per column.
    Value[][] rows;

    this(string name, string[] columns) @safe pure nothrow @nogc
    {
        this.name = name;
        this.columns = columns;
    }

    /// The index of the column called `columnName`, or -1.
    ptrdiff_t columnIndex(string columnName) const @safe pure nothrow @nogc
    {
        foreach (i, c; columns)
            if (c == columnName)
                return i;
        return -1;
    }
}
