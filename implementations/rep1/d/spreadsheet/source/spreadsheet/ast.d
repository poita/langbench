/// The resolved formula AST: plain records in arrays, built once at `set` time.
module spreadsheet.ast;

/// Node kinds.
enum NodeKind : ubyte
{
    number,    /// literal; `num`
    text,      /// string literal; `str`
    cell,      /// reference; `a` = cell handle
    negate,    /// unary minus; `a` = operand node
    binary,    /// `a` op `b`; `op` is a `BinOp`
    conditional, /// IF(a, b, c)
    aggregate, /// `op` is an `AggOp`; arguments are `args[a .. a + b]`
}

/// Binary operators.
enum BinOp : ubyte { add, sub, mul, div, concat, eq, ne, lt, gt, le, ge }

/// Aggregate functions.
enum AggOp : ubyte { sum, min, max, avg, count }

/// One AST node.  Children are indices into `Formula.nodes`.
struct Node
{
    NodeKind kind;
    ubyte op;
    uint a, b, c;
    double num = 0;
    string str;
}

/// An aggregate argument: an expression or a range.
struct Arg
{
    bool isRange;
    uint node;        /// expression node (when not a range)
    uint cellsStart;  /// range cells are `rangeCells[cellsStart .. cellsStart + cellsLen]`
    uint cellsLen;
}

/// A parsed formula whose references are resolved to cell handles.
struct Formula
{
    Node[] nodes;
    Arg[] args;
    /// Handles covered by every range, each range in row-major order.
    uint[] rangeCells;
    uint root;
    /// True if the formula contains an invalid reference: its value is `#REF!`
    /// and it has no dependencies (the other fields are then unused).
    bool invalid;
}
