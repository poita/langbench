/**
 * The syntax tree of a parsed template.
 */
module sitegen.templating.ast;

/// The kinds of expression node.
enum ExprKind : ubyte
{
    intLit,
    floatLit,
    strLit,
    boolLit,
    noneLit,
    name,
    list,
    neg,
    not,
    binary,
    and,
    or,
    compare,
    filter,
    isDefined,
    attr,
    index,
    call,
}

/// Binary arithmetic operators.
enum BinOp : ubyte
{
    add,
    sub,
    mul,
    div,
    floorDiv,
    mod,
    pow,
    concat,
}

/// Comparison operators.
enum CmpOp : ubyte
{
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    in_,
    notIn,
}

/// An expression node.  Which fields are used depends on `kind`.
final class Expr
{
    ExprKind kind;
    long ival;
    double fval;
    /// String literal, name, attribute name or filter name.
    string str;
    bool flag;
    BinOp binOp;
    /// `neg`, `not`, `filter` input, `isDefined` operand, `attr`/`index`
    /// base, `call` callee, and the left side of `and`/`or`/`binary`.
    Expr a;
    /// The right side of `and`/`or`/`binary`, and the key of `index`.
    Expr b;
    /// List elements, call or filter arguments, comparison operands.
    Expr[] args;
    /// Keyword arguments of a call.
    string[] kwNames;
    Expr[] kwValues;
    /// Comparison operators between the operands in `args`.
    CmpOp[] cmpOps;

    this(ExprKind kind)
    {
        this.kind = kind;
    }
}

/// The kinds of statement node.
enum NodeKind : ubyte
{
    text,
    print,
    if_,
    for_,
    set,
    macro_,
    include,
    extends,
    block,
}

/// A macro parameter.
struct Param
{
    string name;
    /// The default value expression, or `null`.
    Expr defaultValue;
}

/// A statement node.  Which fields are used depends on `kind`.
final class Node
{
    NodeKind kind;
    /// Text of a `text` node.
    string text;
    /// The expression of `print`, `set`, `for`, `include` and `extends`.
    Expr expr;
    /// The variable of `set` and `for`, the name of a `macro` or `block`.
    string name;
    /// The bodies of an `if` (one per condition) .
    Node[][] bodies;
    /// The conditions of an `if`.
    Expr[] conds;
    /// The body of `for`, `macro` and `block`.
    Node[] body_;
    /// The `else` body of `if` and `for`.
    Node[] elseBody;
    /// The parameters of a macro.
    Param[] params;

    this(NodeKind kind)
    {
        this.kind = kind;
    }
}

/// A parsed template.
final class Template
{
    string name;
    Node[] body_;
    /// Every `block` of the template, by name.
    Node[string] blocks;
}
