/// The bound (resolved, executable) form of statements and expressions.
module minisql.plan;

import minisql.ast : AggFn, BinOp;
import minisql.table;
import minisql.value;

/// Node kinds of a bound expression.
enum NodeKind : ubyte
{
    constant,
    column, /// reads `row[slot][col]`
    aggRef, /// reads the finished aggregate `aggIndex` of the current group
    neg,
    not,
    binary,
    isNull,
    isNotNull,
}

/// A bound expression node. Column names are already resolved to a
/// (FROM slot, column index) pair and literals are ready-made values.
final class BExpr
{
    NodeKind kind;
    BinOp op;
    BExpr a, b;
    Value value;
    int slot, col, aggIndex;
    /// Bit set of the FROM slots this expression reads (bit 0: first table).
    ubyte mask;
}

/// An aggregate call: its function and per-row argument (null for COUNT(*)).
struct AggSpec
{
    AggFn fn;
    BExpr arg;
}

/// A grouping column.
struct GroupCol
{
    int slot, col;
}

/// One ORDER BY key: a column of the result record and a direction.
struct SortKey
{
    size_t field;
    bool desc;
}

/// A pair of expressions whose equality is the join key: `left` reads only
/// the first table, `right` only the second.
struct KeyPair
{
    BExpr left, right;
}

/// A bound SELECT.
final class BoundSelect
{
    Table[2] tables;
    int slotCount;

    // Row selection (see minisql.executor): conjuncts of ON and WHERE
    // classified by the tables they read.
    BExpr[] firstFilters; /// read only the first table (or none)
    BExpr[] secondFilters; /// read only the second table
    KeyPair[] joinKeys; /// cross-table equalities (hash join key)
    BExpr[] residual; /// remaining conjuncts reading both tables

    // Aggregation
    bool aggregate;
    GroupCol[] groupCols;
    AggSpec[] aggs;
    BExpr having;

    // Projection and ordering
    BExpr[] items; /// the output columns
    BExpr[] extraKeys; /// ORDER BY expressions that are not output columns
    SortKey[] sortKeys; /// field indexes: items first, then extraKeys

    bool hasLimit;
    long limit, offset;
}

/// A bound INSERT: the rows of value expressions (no row in scope).
final class BoundInsert
{
    Table table;
    BExpr[][] rows;
}

/// A bound DELETE.
final class BoundDelete
{
    Table table;
    BExpr[] filters;
}

/// A bound UPDATE.
final class BoundUpdate
{
    Table table;
    int[] columns;
    BExpr[] values;
    BExpr[] filters;
}
