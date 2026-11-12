/**
 * Syntax trees produced by the parser.
 *
 * Nothing here is resolved against a schema; that is the job of the binder
 * (see `minisql.binder`).
 */
module minisql.ast;

import minisql.value : Value;

/// Binary operators of expressions.
enum BinOp : ubyte
{
    add, sub, mul, div, mod,
    eq, ne, lt, le, gt, ge,
    and, or,
}

/// The five aggregate functions.
enum AggFunc : ubyte
{
    count, sum, min, max, avg,
}

/// The shape of an $(LREF Expr) node.
enum ExprKind : ubyte
{
    literal,   /// `value`
    column,    /// `qualifier`, `name`
    negate,    /// `-lhs`
    not,       /// `NOT lhs`
    binary,    /// `lhs op rhs`
    isNull,    /// `lhs IS NULL`
    isNotNull, /// `lhs IS NOT NULL`
    like,      /// `lhs LIKE rhs`
    aggregate, /// `func(lhs)`, or `COUNT(*)` when `star`
}

/// An expression tree node.
final class Expr
{
    ExprKind kind;
    BinOp op;
    AggFunc func;
    bool star;
    Value value;
    string qualifier;
    string name;
    Expr lhs, rhs;

    this(ExprKind kind) @safe pure nothrow @nogc
    {
        this.kind = kind;
    }
}

/// An item of a select list: `*` or an expression with an optional alias.
struct SelectItem
{
    bool star;
    Expr expr;
    string alias_;
}

/// `name [[AS] alias]` in a FROM clause.
struct TableRef
{
    string name;
    string alias_;

    /// The name under which the table's columns are qualified.
    string effectiveName() const @safe pure nothrow @nogc
    {
        return alias_.length ? alias_ : name;
    }
}

/// One term of an ORDER BY clause.
struct OrderTerm
{
    Expr expr;
    bool descending;
}

/// A column reference, as written in GROUP BY.
struct ColumnRef
{
    string qualifier;
    string name;
}

/// The kind of a statement.
enum StmtKind : ubyte
{
    createTable, insert, delete_, update, select,
}

/// A parsed statement; only the members relevant to `kind` are meaningful.
final class Stmt
{
    StmtKind kind;

    /// Target table of CREATE / INSERT / DELETE / UPDATE.
    string table;

    // CREATE TABLE
    string[] columnNames;

    // INSERT
    Expr[][] rows;

    // UPDATE
    string[] setColumns;
    Expr[] setValues;

    // DELETE / UPDATE / SELECT
    Expr where;

    // SELECT
    SelectItem[] items;
    TableRef[] from;
    Expr joinOn;
    ColumnRef[] groupBy;
    Expr having;
    OrderTerm[] orderBy;
    bool hasLimit;
    long limit;
    long offset;

    this(StmtKind kind) @safe pure nothrow @nogc
    {
        this.kind = kind;
    }
}
