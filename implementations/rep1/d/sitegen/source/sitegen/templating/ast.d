/// Syntax tree of a parsed template.
module sitegen.templating.ast;

import sitegen.templating.value;

/// Expression node kinds.
enum ExprKind : ubyte
{
    literal,
    name,
    attr,
    index,
    call,
    filter,
    isDefined,
    neg,
    not,
    binary,
    compare,
    and,
    or,
    list,
}

/// Binary arithmetic operators, resolved at parse time.
enum BinOp : ubyte
{
    add, sub, mul, div, floorDiv, mod, pow, concat,
}

/// Comparison operators.
enum CmpOp : ubyte
{
    eq, ne, lt, le, gt, ge, in_, notIn,
}

/// The built-in filters; `unknown` is reported after the whole template parsed.
enum FilterId : ubyte
{
    upper, lower, trim, escape, replace, length, int_, join,
    first, last, reverse, sort, default_, unknown,
}

/// An expression. One class with a kind tag keeps evaluation to one switch.
final class Expr
{
    ExprKind kind;
    Value lit; /// literal value
    string name; /// variable name, attribute key or filter name
    Expr a, b; /// operands (callee / subject / left / right)
    Expr[] args; /// call arguments, list items, further compare operands
    string[] kwNames; /// keyword argument names of a call
    Expr[] kwArgs; /// keyword argument values of a call
    BinOp bop;
    CmpOp[] cmpOps;
    FilterId filter;
    bool negate; /// `is not defined`
    bool isRangeName; /// a name that falls back to the built-in `range`
    bool isSuperName;

    this(ExprKind kind) pure nothrow @safe @nogc
    {
        this.kind = kind;
    }
}

/// Statement node kinds.
enum StmtKind : ubyte
{
    text,
    print,
    if_,
    for_,
    set,
    macroDef,
    include,
    extends,
    block,
}

/// A template statement (including literal text and `{{ }}` prints).
final class Stmt
{
    StmtKind kind;
    string text; /// literal text
    Expr expr; /// print / set / include / extends / for-iterable
    Expr[] conds; /// `if` / `elif` conditions
    Stmt[][] bodies; /// bodies matching `conds`
    Stmt[] body_; /// for / macro / block body
    Stmt[] elseBody; /// `else` branch of if / for
    string name; /// set / for variable / macro / block name
    string[] params; /// macro parameters
    Expr[] defaults; /// macro parameter defaults (null when none)

    this(StmtKind kind) pure nothrow @safe @nogc
    {
        this.kind = kind;
    }
}

/// A parsed and checked template.
final class Template
{
    string name;
    Stmt[] body_;
    Stmt[] blocks; /// every `block` statement, in source order
}
