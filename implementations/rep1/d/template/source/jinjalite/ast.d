/// Syntax tree produced by the parser and walked by the interpreter.
module jinjalite.ast;

import jinjalite.operators : BinOp, CmpOp;
import jinjalite.value : Value;
import jinjalite.filters : FilterId;

/// Discriminator for `Expr` nodes.
enum ExprKind : ubyte
{
    literal, name, list, negate, not, binary, logic, compare, filter, isDefined, attribute, subscript, call,
}

/// Base class of expression nodes.
abstract class Expr
{
    /// Which concrete node this is.
    immutable ExprKind kind;

    protected this(ExprKind kind) pure nothrow @safe @nogc
    {
        this.kind = kind;
    }
}

/// A constant: number, string, boolean or none.
final class Literal : Expr
{
    /// The constant value.
    Value value;
    ///
    this(Value value) { super(ExprKind.literal); this.value = value; }
}

/// A variable reference.
final class NameExpr : Expr
{
    /// The variable name.
    string name;
    ///
    this(string name) { super(ExprKind.name); this.name = name; }
}

/// A list literal `[a, b]`.
final class ListExpr : Expr
{
    /// Element expressions.
    Expr[] items;
    ///
    this(Expr[] items) { super(ExprKind.list); this.items = items; }
}

/// Unary minus or `not`, distinguished by `kind`.
final class UnaryExpr : Expr
{
    /// The operand.
    Expr operand;
    ///
    this(ExprKind kind, Expr operand) { super(kind); this.operand = operand; }
}

/// An arithmetic or `~` expression.
final class BinaryExpr : Expr
{
    /// The operator.
    BinOp op;
    /// Left and right operands.
    Expr lhs, rhs;
    ///
    this(BinOp op, Expr lhs, Expr rhs) { super(ExprKind.binary); this.op = op; this.lhs = lhs; this.rhs = rhs; }
}

/// Short-circuiting `and` / `or`.
final class LogicExpr : Expr
{
    /// True for `and`, false for `or`.
    bool isAnd;
    /// Left and right operands.
    Expr lhs, rhs;
    ///
    this(bool isAnd, Expr lhs, Expr rhs) { super(ExprKind.logic); this.isAnd = isAnd; this.lhs = lhs; this.rhs = rhs; }
}

/// A (possibly chained) comparison `first op0 operands[0] op1 operands[1] ...`.
final class CompareExpr : Expr
{
    /// The leftmost operand.
    Expr first;
    /// The operators, one per further operand.
    CmpOp[] ops;
    /// The operands after the first.
    Expr[] operands;
    ///
    this(Expr first, CmpOp[] ops, Expr[] operands)
    {
        super(ExprKind.compare);
        this.first = first; this.ops = ops; this.operands = operands;
    }
}

/// `input|name(args)`.
final class FilterExpr : Expr
{
    /// The filtered expression.
    Expr input;
    /// The resolved filter (`FilterId.unknown` is reported when the template is loaded).
    FilterId id;
    /// The filter's arguments.
    Expr[] args;
    ///
    this(Expr input, FilterId id, Expr[] args)
    {
        super(ExprKind.filter);
        this.input = input; this.id = id; this.args = args;
    }
}

/// `operand is defined` / `operand is not defined`.
final class IsDefinedExpr : Expr
{
    /// The tested expression.
    Expr operand;
    /// True for `is not defined`.
    bool negated;
    ///
    this(Expr operand, bool negated) { super(ExprKind.isDefined); this.operand = operand; this.negated = negated; }
}

/// `object.name`.
final class AttrExpr : Expr
{
    /// The object expression.
    Expr object;
    /// The attribute name.
    string name;
    ///
    this(Expr object, string name) { super(ExprKind.attribute); this.object = object; this.name = name; }
}

/// `object[key]`.
final class SubscriptExpr : Expr
{
    /// The object expression.
    Expr object;
    /// The key expression.
    Expr key;
    ///
    this(Expr object, Expr key) { super(ExprKind.subscript); this.object = object; this.key = key; }
}

/// `callee(args, name=value)`.
final class CallExpr : Expr
{
    /// The called expression.
    Expr callee;
    /// Positional arguments.
    Expr[] args;
    /// Keyword argument names, parallel to `kwValues`.
    string[] kwNames;
    /// Keyword argument values.
    Expr[] kwValues;
    ///
    this(Expr callee, Expr[] args, string[] kwNames, Expr[] kwValues)
    {
        super(ExprKind.call);
        this.callee = callee; this.args = args; this.kwNames = kwNames; this.kwValues = kwValues;
    }
}

/// Discriminator for `Stmt` nodes.
enum StmtKind : ubyte { text, print, if_, for_, set, macroDef, include, extends, block }

/// Base class of statement nodes.
abstract class Stmt
{
    /// Which concrete node this is.
    immutable StmtKind kind;

    protected this(StmtKind kind) pure nothrow @safe @nogc
    {
        this.kind = kind;
    }
}

/// Literal text.
final class TextStmt : Stmt
{
    /// The text, after whitespace control.
    string text;
    ///
    this(string text) { super(StmtKind.text); this.text = text; }
}

/// `{{ expr }}`.
final class PrintStmt : Stmt
{
    /// The printed expression.
    Expr expr;
    ///
    this(Expr expr) { super(StmtKind.print); this.expr = expr; }
}

/// `if` / `elif` / `else`.
final class IfStmt : Stmt
{
    /// Conditions of the `if` and each `elif`.
    Expr[] conds;
    /// The body of each condition.
    Stmt[][] bodies;
    /// The `else` body (empty when absent).
    Stmt[] elseBody;
    ///
    this() { super(StmtKind.if_); }
}

/// `for NAME in iterable` with optional `else`.
final class ForStmt : Stmt
{
    /// The loop variable.
    string var;
    /// The iterated expression.
    Expr iterable;
    /// Loop body and `else` body.
    Stmt[] stmts, elseBody;
    ///
    this(string var, Expr iterable) { super(StmtKind.for_); this.var = var; this.iterable = iterable; }
}

/// `set NAME = value`.
final class SetStmt : Stmt
{
    /// The assigned name.
    string name;
    /// The assigned expression.
    Expr value;
    ///
    this(string name, Expr value) { super(StmtKind.set); this.name = name; this.value = value; }
}

/// A macro parameter with an optional default expression.
struct Param
{
    /// Parameter name.
    string name;
    /// Default value expression, or `null`.
    Expr defaultValue;
}

/// `macro NAME(params)`.
final class MacroStmt : Stmt
{
    /// The macro's name.
    string name;
    /// Its parameters.
    Param[] params;
    /// Its body.
    Stmt[] stmts;
    ///
    this(string name) { super(StmtKind.macroDef); this.name = name; }
}

/// `include expr`.
final class IncludeStmt : Stmt
{
    /// The expression naming the template.
    Expr target;
    ///
    this(Expr target) { super(StmtKind.include); this.target = target; }
}

/// `extends expr`.
final class ExtendsStmt : Stmt
{
    /// The expression naming the parent template.
    Expr target;
    ///
    this(Expr target) { super(StmtKind.extends); this.target = target; }
}

/// `block NAME`.
final class BlockStmt : Stmt
{
    /// The block's name.
    string name;
    /// The block's body.
    Stmt[] stmts;
    ///
    this(string name) { super(StmtKind.block); this.name = name; }
}

/// A parsed template.
final class Template
{
    /// The template's name.
    string name;
    /// Its top-level statements.
    Stmt[] stmts;
    /// The static block table: every block of the template, wherever it appears.
    BlockStmt[string] blocks;
    ///
    this(string name) { this.name = name; }
}
