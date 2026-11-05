/// The result of executing a statement.
module minisql.result;

import std.array : Appender;
import minisql.value;

/// The rows produced by a statement. Only SELECT produces a result set;
/// `CREATE`, `INSERT`, `UPDATE` and `DELETE` return one with `isQuery == false`.
struct Result
{
    /// True when the statement was a SELECT.
    bool isQuery;
    /// Number of values per row.
    size_t width;
    /// All values, row-major: row `i` is `cells[i * width .. (i + 1) * width]`.
    Value[] cells;
    /// Number of rows.
    size_t rowCount;

    /// The values of row `i`.
    const(Value)[] row(size_t i) const pure nothrow @nogc @safe
    {
        return cells[i * width .. (i + 1) * width];
    }
}

/// Appends a result in the command-line format: one line per row with
/// tab-separated values, then `-- N rows`. Non-queries print nothing.
void appendResult(ref Appender!(char[]) sink, const ref Result r) pure @safe
{
    if (!r.isQuery)
        return;
    foreach (i; 0 .. r.rowCount)
    {
        foreach (j, ref v; r.row(i))
        {
            if (j)
                sink.put('\t');
            appendValue(sink, v);
        }
        sink.put('\n');
    }
    sink.put("-- ");
    char[24] tmp = void;
    sink.put(formatInteger(cast(long) r.rowCount, tmp[]));
    sink.put(" rows\n");
}
