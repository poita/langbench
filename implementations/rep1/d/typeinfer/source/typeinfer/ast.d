/**
 * Abstract syntax tree of the source language.
 *
 * `let f x y = e` is desugared by the parser into a $(LREF Let) whose
 * right-hand side is a multi-parameter $(LREF Lam).
 */
module typeinfer.ast;

/// Discriminator for $(LREF Expr) subclasses (so consumers can `switch` and `cast`).
enum ExprKind : ubyte
{
    intLit, boolLit, unitLit, nil, var, lam, app, let, ifThenElse, tuple, list, binary, cons,
}

/// Binary operators on `int` / `bool` operands.
enum BinOp : ubyte
{
    add, sub, mul, div,   // int -> int -> int
    eq, lt, gt, le, ge,   // int -> int -> bool
    and, or,              // bool -> bool -> bool
}

/// Base class of expressions.
abstract class Expr
{
    /// Which subclass this is.
    immutable ExprKind kind;

    protected this(ExprKind kind) @safe nothrow @nogc { this.kind = kind; }
}

/// Integer literal (its value is irrelevant to typing, so only the text is kept).
final class IntLit : Expr
{
    string text;
    this(string text) @safe nothrow @nogc { super(ExprKind.intLit); this.text = text; }
}

/// `true` or `false`.
final class BoolLit : Expr
{
    bool value;
    this(bool value) @safe nothrow @nogc { super(ExprKind.boolLit); this.value = value; }
}

/// `()`.
final class UnitLit : Expr
{
    this() @safe nothrow @nogc { super(ExprKind.unitLit); }
}

/// `[]`.
final class Nil : Expr
{
    this() @safe nothrow @nogc { super(ExprKind.nil); }
}

/// A variable reference.
final class Var : Expr
{
    string name;
    this(string name) @safe nothrow @nogc { super(ExprKind.var); this.name = name; }
}

/// `fun p1 ... pn -> body` (n >= 1).
final class Lam : Expr
{
    string[] params;
    Expr body;
    this(string[] params, Expr body) @safe nothrow @nogc
    {
        super(ExprKind.lam);
        this.params = params;
        this.body = body;
    }
}

/// Application `fn arg`.
final class App : Expr
{
    Expr fn, arg;
    this(Expr fn, Expr arg) @safe nothrow @nogc { super(ExprKind.app); this.fn = fn; this.arg = arg; }
}

/// `let name = rhs in body` or, when `isRec`, `let rec name = rhs in body`.
final class Let : Expr
{
    string name;
    bool isRec;
    Expr rhs, body;
    this(string name, bool isRec, Expr rhs, Expr body) @safe nothrow @nogc
    {
        super(ExprKind.let);
        this.name = name;
        this.isRec = isRec;
        this.rhs = rhs;
        this.body = body;
    }
}

/// `if cond then thenBranch else elseBranch`.
final class If : Expr
{
    Expr cond, thenBranch, elseBranch;
    this(Expr c, Expr t, Expr e) @safe nothrow @nogc
    {
        super(ExprKind.ifThenElse);
        cond = c;
        thenBranch = t;
        elseBranch = e;
    }
}

/// Tuple of two or more elements.
final class Tuple : Expr
{
    Expr[] elems;
    this(Expr[] elems) @safe nothrow @nogc { super(ExprKind.tuple); this.elems = elems; }
}

/// List literal `[e1; ...; en]` (n >= 1).
final class ListLit : Expr
{
    Expr[] elems;
    this(Expr[] elems) @safe nothrow @nogc { super(ExprKind.list); this.elems = elems; }
}

/// `lhs op rhs` for the arithmetic, comparison and boolean operators.
final class Binary : Expr
{
    BinOp op;
    Expr lhs, rhs;
    this(BinOp op, Expr lhs, Expr rhs) @safe nothrow @nogc
    {
        super(ExprKind.binary);
        this.op = op;
        this.lhs = lhs;
        this.rhs = rhs;
    }
}

/// `head :: tail`.
final class Cons : Expr
{
    Expr head, tail;
    this(Expr head, Expr tail) @safe nothrow @nogc
    {
        super(ExprKind.cons);
        this.head = head;
        this.tail = tail;
    }
}

/// A top-level declaration.
struct Decl
{
    /// Bound name; empty for a bare expression.
    string name;
    /// True for `let rec`.
    bool isRec;
    /// The right-hand side (for a binding) or the expression itself.
    Expr expr;

    /// Whether this declaration binds a name (as opposed to being a bare expression).
    bool isBinding() const @safe nothrow @nogc { return name.length != 0; }
}
