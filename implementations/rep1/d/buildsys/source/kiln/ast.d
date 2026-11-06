/// Abstract syntax tree of KBL.
module kiln.ast;

/// Expression node kinds.
enum ExprKind : ubyte
{
    intLit,
    strLit,
    boolLit,
    interp, /// double-quoted literal with interpolations
    variable,
    list,
    call,
    index,
    unary,
    binary,
    logicalAnd,
    logicalOr
}

/// Unary and binary operators.
enum Op : ubyte
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
    concatStr,
    concatList,
    neg,
    not
}

/// The spelling of an operator, used in error sites.
string opSpelling(Op op) pure nothrow @safe
{
    final switch (op)
    {
    case Op.add:
        return "+";
    case Op.sub:
        return "-";
    case Op.mul:
        return "*";
    case Op.div:
        return "/";
    case Op.mod:
        return "%";
    case Op.eq:
        return "==";
    case Op.ne:
        return "!=";
    case Op.lt:
        return "<";
    case Op.le:
        return "<=";
    case Op.gt:
        return ">";
    case Op.ge:
        return ">=";
    case Op.concatStr:
        return "~";
    case Op.concatList:
        return "++";
    case Op.neg:
        return "-";
    case Op.not:
        return "!";
    }
}

/// A piece of a double-quoted literal: literal text or an interpolated expression.
struct StrPart
{
    string text;
    Expr expr; /// null for a literal part
}

/// An expression.
final class Expr
{
    ExprKind kind;
    long ival; /// integer / bool literal
    string name; /// string literal text, variable name or called function name
    Op op; /// for unary / binary
    Expr[] kids; /// operands, list elements, call arguments, index operands
    StrPart[] parts; /// for `interp`
}

/// Statement node kinds.
enum StmtKind : ubyte
{
    let,
    set,
    include,
    abort,
    default_,
    phony,
    use,
    when,
    each,
    rule,
    step
}

/// Step field kinds.
enum FieldKind : ubyte
{
    out_,
    in_,
    after,
    cost,
    depfile,
    cmd
}

/// A `field expr` or `cmd name(args)` line inside a step block.
struct StepField
{
    FieldKind kind;
    Expr expr;
    string cmdName;
    Expr[] args;
}

/// A rule parameter with an optional default.
struct Param
{
    string name;
    Expr def; /// null when there is no default
}

/// A keyword argument of a `use` statement.
struct KwArg
{
    string name;
    Expr value;
}

/// A statement.
final class Stmt
{
    StmtKind kind;
    int line;
    string name; /// let/set/phony/use/rule name; each element variable
    string indexName; /// `each` index variable (null if absent)
    Expr expr; /// the main expression (let, set, include, abort, default, phony, each subject)
    Expr[] posArgs; /// use: positional arguments
    KwArg[] kwArgs; /// use: keyword arguments
    Expr[] conds; /// when/elsewhen conditions
    Stmt[][] bodies; /// when/elsewhen bodies (same length as conds)
    Stmt[] otherwise; /// `otherwise` body
    bool hasOtherwise;
    Stmt[] body; /// each/rule body
    Param[] params; /// rule parameters
    StepField[] fields; /// step fields
}
