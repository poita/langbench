/**
 * Syntax trees for KBL expressions and statements.
 */
module kiln.ast;

import kiln.value : Value;

/// Binary operators.
enum BinOp : ubyte
{
    or,
    and,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    listCat,
    strCat,
    add,
    sub,
    mul,
    div,
    mod,
}

/// Unary operators.
enum UnOp : ubyte
{
    not,
    neg,
}

/// The spelling of a binary operator.
string spelling(BinOp op) @safe pure nothrow @nogc
{
    static immutable string[] names = [
        "||", "&&", "==", "!=", "<", "<=", ">", ">=", "++", "~", "+", "-", "*", "/", "%"
    ];
    return names[op];
}

/// The spelling of a unary operator.
string spelling(UnOp op) @safe pure nothrow @nogc
{
    return op == UnOp.not ? "!" : "-";
}

/// Expression node kinds.
enum ExprKind : ubyte
{
    literal, /// `lit`
    interpolated, /// `parts`
    variable, /// `name`
    list, /// `args`
    unary, /// `unop`, `lhs`
    binary, /// `binop`, `lhs`, `rhs`
    call, /// `name`, `args`
    index, /// `lhs` indexed by `rhs`
}

/// One piece of a double-quoted string literal.
struct StrPart
{
    string text; /// Literal bytes (when `expr` is null).
    Expr expr; /// Interpolated expression, or null for a literal piece.
}

/// An expression node.
final class Expr
{
    ExprKind kind;
    Value lit;
    string name;
    BinOp binop;
    UnOp unop;
    Expr lhs, rhs;
    Expr[] args;
    StrPart[] parts;
    /// Cached built-in lookup for `call` nodes (set by the evaluator).
    const(void)* resolved;
}

/// Statement node kinds.
enum StmtKind : ubyte
{
    let,
    set,
    include,
    abort,
    defaultTargets,
    phony,
    use,
    when,
    each,
    rule,
    step,
    // step fields
    fieldOut,
    fieldIn,
    fieldAfter,
    fieldCost,
    fieldDepfile,
    fieldCmd,
}

/// An argument of a `use` statement.
struct UseArg
{
    string keyword; /// Empty for a positional argument.
    Expr value;
}

/// A rule parameter.
struct Param
{
    string name;
    Expr defaultValue; /// Null if the parameter has no default.
}

/// A statement node.
final class Stmt
{
    StmtKind kind;
    int line;
    string name; // let/set/phony name, use/rule name, cmd name, each value var
    string indexName; // each: the index variable ("" if absent)
    Expr expr; // let/set/include/abort/default/phony/each subject/field value
    Expr[] conds; // when/elsewhen conditions
    Stmt[][] branches; // when/elsewhen bodies
    Stmt[] otherwise; // otherwise body
    bool hasOtherwise;
    Stmt[] children; // each, rule body
    Stmt[] fields; // step fields
    Param[] params; // rule
    UseArg[] useArgs; // use
    Expr[] cmdArgs; // cmd field
}
