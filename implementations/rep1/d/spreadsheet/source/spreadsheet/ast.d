/**
 * Syntax tree for formulas.
 *
 * A formula is parsed once (see $(MREF spreadsheet.parser)) into an $(LREF Expr)
 * tree with resolved cell references; evaluation (see $(MREF spreadsheet.eval))
 * only ever walks the tree.
 */
module spreadsheet.ast;

import spreadsheet.cellref;
import spreadsheet.value;

/// Binary operators, from the grammar's `add`, `mul`, `cat` and `cmp` levels.
enum BinaryOp : ubyte
{
    add, sub, mul, div,
    concat,
    eq, ne, lt, gt, le, ge,
}

/// The aggregate functions.
enum Aggregate : ubyte
{
    sum, min, max, avg, count,
}

/// Node kinds of the formula tree.
enum ExprKind : ubyte
{
    number,    /// numeric literal: `value`
    text,      /// string literal: `value`
    error,     /// constant error (used for formulas containing invalid references)
    reference, /// a single cell: `cell`
    range,     /// a rectangle of cells (aggregate argument only): `cell`, `cellEnd`
    negate,    /// unary minus: `args[0]`
    binary,    /// `op` applied to `args[0]`, `args[1]`
    conditional, /// `IF(args[0], args[1], args[2])`
    aggregate, /// `fn` applied to `args`
}

/// One node of a formula syntax tree.
final class Expr
{
    ExprKind kind;
    /// Literal for `number`, `text` and `error` nodes.
    Value value;
    /// The cell for `reference`; the first corner for `range`.
    CellRef cell;
    /// The second corner of a `range`.
    CellRef cellEnd;
    /// Operator of a `binary` node.
    BinaryOp op;
    /// Function of an `aggregate` node.
    Aggregate fn;
    /// Child expressions.
    Expr[] args;

    this(ExprKind kind) pure nothrow @nogc @safe
    {
        this.kind = kind;
    }

    /// A literal node holding `v` (kind is chosen from the value).
    static Expr literal(Value v) pure nothrow @safe
    {
        Expr e;
        final switch (v.kind)
        {
        case ValueKind.number: e = new Expr(ExprKind.number); break;
        case ValueKind.text:   e = new Expr(ExprKind.text); break;
        case ValueKind.error:  e = new Expr(ExprKind.error); break;
        case ValueKind.empty:  assert(0, "no empty literal");
        }
        e.value = v;
        return e;
    }
}

/**
 * Appends every cell the expression depends on (single references plus every
 * cell covered by a range) to `sink`; duplicates are not removed.
 * Both branches of an `IF` count.
 */
void collectDependencies(const Expr e, ref uint[] sink) pure nothrow @safe
{
    final switch (e.kind)
    {
    case ExprKind.number:
    case ExprKind.text:
    case ExprKind.error:
        break;
    case ExprKind.reference:
        sink ~= e.cell.key;
        break;
    case ExprKind.range:
        foreach (key; rangeKeys(e.cell, e.cellEnd))
            sink ~= key;
        break;
    case ExprKind.negate:
    case ExprKind.binary:
    case ExprKind.conditional:
    case ExprKind.aggregate:
        foreach (a; e.args)
            collectDependencies(a, sink);
        break;
    }
}

/// Iterates the keys of the rectangle spanned by two corners (either order), row-major.
auto rangeKeys(CellRef a, CellRef b) pure nothrow @nogc @safe
{
    static struct Keys
    {
        ushort c0, c1, r1, c, r;
        bool done;
        @property bool empty() const { return done; }
        @property uint front() const { return (cast(uint) r << 10) | c; }
        void popFront()
        {
            if (c < c1)
                c++;
            else if (r < r1)
            {
                c = c0;
                r++;
            }
            else
                done = true;
        }
    }
    import std.algorithm.comparison : min, max;
    const c0 = cast(ushort) min(a.column, b.column);
    const r0 = cast(ushort) min(a.row, b.row);
    return Keys(c0, cast(ushort) max(a.column, b.column), cast(ushort) max(a.row, b.row), c0, r0);
}

@safe pure nothrow unittest
{
    import std.array : array;
    auto keys = rangeKeys(CellRef(2, 2), CellRef(1, 1)).array;
    assert(keys == [CellRef(1, 1).key, CellRef(2, 1).key, CellRef(1, 2).key, CellRef(2, 2).key]);
    assert(rangeKeys(CellRef(3, 4), CellRef(3, 4)).array == [CellRef(3, 4).key]);
}
