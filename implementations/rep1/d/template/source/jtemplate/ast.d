/// Syntax tree of a parsed template.
///
/// Nodes carry a `kind` tag; the interpreter switches on it and downcasts
/// with a plain pointer cast, so evaluation costs one branch per node.
module jtemplate.ast;

import jtemplate.value : Value;

/// Binary arithmetic operators (resolved at parse time).
enum BinOp : ubyte { add, sub, mul, div, floorDiv, mod, pow, concat }

/// Comparison operators (resolved at parse time).
enum CmpOp : ubyte { eq, ne, lt, le, gt, ge, in_, notIn }

/// The built-in filters. `unknown` marks a name that is not a filter.
enum FilterId : ubyte
{
    unknown, upper, lower, trim, escape, replace, length, int_,
    join, first, last, reverse, sort, default_,
}

/// Expression node kinds.
enum ExprKind : ubyte
{
    literal, name, attr, index, call, neg, not, binary, compare,
    and, or, filter, defined, list,
}

/// Base class of expression nodes.
class Expr
{
    /// Node tag used for dispatch.
    const ExprKind kind;
    ///
    this(ExprKind kind) pure nothrow @safe @nogc { this.kind = kind; }
}

/// A literal value, built once at parse time.
final class LiteralExpr : Expr
{
    Value value; ///
    ///
    this(Value value) { super(ExprKind.literal); this.value = value; }
}

/// A variable reference.
final class NameExpr : Expr
{
    string name;    ///
    bool isRange;   /// the name is `range` (falls back to the built-in)
    ///
    this(string name) { super(ExprKind.name); this.name = name; isRange = name == "range"; }
}

/// `obj.name`; the key is built as a string value once.
final class AttrExpr : Expr
{
    Expr obj;    ///
    Value key;   ///
    ///
    this(Expr obj, string name)
    {
        super(ExprKind.attr);
        this.obj = obj;
        key = Value.fromString(name);
    }
}

/// `obj[index]`.
final class IndexExpr : Expr
{
    Expr obj;    ///
    Expr index;  ///
    ///
    this(Expr obj, Expr index) { super(ExprKind.index); this.obj = obj; this.index = index; }
}

/// `callee(args, name=value, ...)`.
final class CallExpr : Expr
{
    Expr callee;          ///
    Expr[] args;          /// positional arguments
    string[] kwNames;     /// keyword names
    Expr[] kwValues;      /// keyword values, parallel to `kwNames`
    ///
    this(Expr callee, Expr[] args, string[] kwNames, Expr[] kwValues)
    {
        super(ExprKind.call);
        this.callee = callee;
        this.args = args;
        this.kwNames = kwNames;
        this.kwValues = kwValues;
    }
}

/// Unary minus (`neg`) or `not`.
final class UnaryExpr : Expr
{
    Expr operand; ///
    ///
    this(ExprKind kind, Expr operand) { super(kind); this.operand = operand; }
}

/// A binary arithmetic or concatenation operation.
final class BinaryExpr : Expr
{
    BinOp op;     ///
    Expr lhs;     ///
    Expr rhs;     ///
    ///
    this(BinOp op, Expr lhs, Expr rhs)
    {
        super(ExprKind.binary);
        this.op = op; this.lhs = lhs; this.rhs = rhs;
    }
}

/// A (possibly chained) comparison: `first op0 rest[0] op1 rest[1] ...`.
final class CompareExpr : Expr
{
    Expr first;     ///
    CmpOp[] ops;    ///
    Expr[] rest;    ///
    ///
    this(Expr first, CmpOp[] ops, Expr[] rest)
    {
        super(ExprKind.compare);
        this.first = first; this.ops = ops; this.rest = rest;
    }
}

/// `lhs and rhs` / `lhs or rhs` (short-circuiting, yields an operand).
final class LogicExpr : Expr
{
    Expr lhs; ///
    Expr rhs; ///
    ///
    this(ExprKind kind, Expr lhs, Expr rhs) { super(kind); this.lhs = lhs; this.rhs = rhs; }
}

/// `input|name(args)`.
final class FilterExpr : Expr
{
    Expr input;     ///
    FilterId id;    ///
    string name;    /// as written in the template
    Expr[] args;    ///
    ///
    this(Expr input, FilterId id, string name, Expr[] args)
    {
        super(ExprKind.filter);
        this.input = input; this.id = id; this.name = name; this.args = args;
    }
}

/// `input is defined` / `input is not defined`.
final class DefinedExpr : Expr
{
    Expr input;   ///
    bool negate;  ///
    ///
    this(Expr input, bool negate)
    {
        super(ExprKind.defined);
        this.input = input; this.negate = negate;
    }
}

/// A list literal.
final class ListExpr : Expr
{
    Expr[] items; ///
    ///
    this(Expr[] items) { super(ExprKind.list); this.items = items; }
}

// ---------------------------------------------------------------------------

/// Statement node kinds.
enum NodeKind : ubyte { text, print, if_, for_, set, macro_, include, extends, block }

/// Base class of statement nodes.
class Node
{
    /// Node tag used for dispatch.
    const NodeKind kind;
    ///
    this(NodeKind kind) pure nothrow @safe @nogc { this.kind = kind; }
}

/// Literal text.
final class TextNode : Node
{
    string text; ///
    ///
    this(string text) { super(NodeKind.text); this.text = text; }
}

/// `{{ expr }}`.
final class PrintNode : Node
{
    Expr expr; ///
    ///
    this(Expr expr) { super(NodeKind.print); this.expr = expr; }
}

/// `if` / `elif` / `else`.
final class IfNode : Node
{
    Expr[] conds;       /// condition of the `if` and each `elif`
    Node[][] bodies;    /// body for each condition
    Node[] elseBody;    ///
    ///
    this() { super(NodeKind.if_); }
}

/// `for NAME in expr` with optional `else`.
final class ForNode : Node
{
    string var;         ///
    Expr iterable;      ///
    Node[] body;        ///
    Node[] elseBody;    ///
    ///
    this(string var, Expr iterable)
    {
        super(NodeKind.for_);
        this.var = var; this.iterable = iterable;
    }
}

/// `set NAME = expr`.
final class SetNode : Node
{
    string name;  ///
    Expr expr;    ///
    ///
    this(string name, Expr expr) { super(NodeKind.set); this.name = name; this.expr = expr; }
}

/// `macro NAME(params)`.
final class MacroNode : Node
{
    string name;        ///
    string[] params;    ///
    Expr[] defaults;    /// default expression per parameter, or null
    Node[] body;        ///
    ///
    this(string name) { super(NodeKind.macro_); this.name = name; }
}

/// `include expr`.
final class IncludeNode : Node
{
    Expr expr; ///
    ///
    this(Expr expr) { super(NodeKind.include); this.expr = expr; }
}

/// `extends expr`.
final class ExtendsNode : Node
{
    Expr expr; ///
    ///
    this(Expr expr) { super(NodeKind.extends); this.expr = expr; }
}

/// `block NAME`.
final class BlockNode : Node
{
    string name;  ///
    Node[] body;  ///
    ///
    this(string name) { super(NodeKind.block); this.name = name; }
}

/// A parsed, checked template.
final class Template
{
    string name;                  ///
    Node[] body;                  /// top-level nodes
    BlockNode[string] blocks;     /// every block in the template, by name
}

/// Downcast without a runtime type check; the caller has switched on `kind`.
T as(T, B)(B node) @trusted pure nothrow @nogc
{
    return cast(T) cast(void*) node;
}
