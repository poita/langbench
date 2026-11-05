/// Syntax trees produced by the parser. They are purely syntactic: names are
/// not yet resolved against any schema (see `minisql.binder`).
module minisql.ast;

/// Binary operators, in no particular order.
enum BinOp : ubyte
{
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and,
    or,
    like,
}

/// The aggregate functions.
enum AggFn : ubyte
{
    count,
    sum,
    min,
    max,
    avg,
}

/// What an `Expr` node is.
enum ExprKind : ubyte
{
    intLit, /// `intValue`
    strLit, /// `text`
    nullLit,
    column, /// `qualifier` (may be null) and `text` (the column name)
    neg, /// unary minus on `lhs`
    not, /// NOT `lhs`
    binary, /// `lhs op rhs`
    isNull, /// `lhs` IS NULL
    isNotNull, /// `lhs` IS NOT NULL
    aggregate, /// `fn`(`lhs`), or COUNT(*) when `star`
}

/// An expression tree node.
final class Expr
{
    ExprKind kind;
    BinOp op;
    AggFn fn;
    bool star;
    Expr lhs, rhs;
    long intValue;
    string text;
    string qualifier;
}

/// A table in a FROM clause, with its optional alias.
struct TableRef
{
    string name;
    string alias_;

    /// The name columns are qualified with: the alias if given, else the table.
    string effective() const pure nothrow @nogc @safe
    {
        return alias_ !is null ? alias_ : name;
    }
}

/// An item of a select list: `*` or an expression with an optional alias.
struct SelectItem
{
    bool star;
    Expr expr;
    string alias_;
}

/// A possibly qualified column name.
struct ColumnRef
{
    string qualifier;
    string name;
}

/// One ORDER BY term.
struct OrderTerm
{
    Expr expr;
    bool desc;
}

/// Base class of all statements.
abstract class Statement
{
}

/// `CREATE TABLE name (col type, ...)`.
final class CreateStmt : Statement
{
    string table;
    string[] columns;
}

/// `INSERT INTO name VALUES (...), (...)`.
final class InsertStmt : Statement
{
    string table;
    Expr[][] rows;
}

/// `DELETE FROM name [WHERE expr]`.
final class DeleteStmt : Statement
{
    string table;
    Expr where_;
}

/// `UPDATE name SET col = expr, ... [WHERE expr]`.
final class UpdateStmt : Statement
{
    string table;
    string[] columns;
    Expr[] values;
    Expr where_;
}

/// A SELECT statement.
final class SelectStmt : Statement
{
    SelectItem[] items;
    TableRef[] from; /// zero, one or two tables
    Expr on; /// the JOIN ... ON expression, if any
    Expr where_;
    ColumnRef[] groupBy;
    Expr having;
    OrderTerm[] orderBy;
    bool hasLimit;
    long limit;
    long offset;
}
