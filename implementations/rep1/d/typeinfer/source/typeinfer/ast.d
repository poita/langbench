/**
 * Compact abstract syntax tree.
 *
 * Expressions live in one flat array and refer to each other by index; the
 * children of tuples and list literals are stored contiguously in a shared
 * pool. Identifiers are interned ids (see `typeinfer.lexer.Interner`).
 */
module typeinfer.ast;

/// What an `Expr` node is. The meaning of its fields `a`, `b`, `c` follows.
enum ExprKind : ubyte
{
    intLit,     /// integer literal
    boolLit,    /// `a` = 1 for `true`, 0 for `false`
    unitLit,    /// `()`
    variable,   /// `a` = name id
    app,        /// `a` = function, `b` = argument (expression indices)
    fun,        /// `a` = parameter name id, `b` = body
    ifThenElse, /// `a` = condition, `b` = then branch, `c` = else branch
    let,        /// `a` = name id, `b` = right-hand side, `c` = body
    letRec,     /// as `let`; the right-hand side is a `fun` node
    tuple,      /// `a` = first index into `Program.children`, `b` = count (>= 2)
    list,       /// as `tuple`, count >= 0
    cons,       /// `a` = head, `b` = tail
    binary,     /// `op` = operator, `a` = left, `b` = right
}

/// Binary operators with built-in monomorphic types.
enum BinOp : ubyte
{
    add, sub, mul, div, // int -> int -> int
    eq, lt, gt, le, ge, // int -> int -> bool
    and, or,            // bool -> bool -> bool
}

/// One expression node.
struct Expr
{
    ExprKind kind;
    BinOp op;
    int a, b, c;
}

/// What a top-level declaration is.
enum DeclKind : ubyte
{
    let,    /// `let name ... = expr;;`
    letRec, /// `let rec name ... = expr;;`
    expr,   /// a bare expression
}

/// A top-level declaration; `expr` is an index into `Program.exprs`.
struct Decl
{
    DeclKind kind;
    int name; /// name id for `let` / `letRec`, otherwise -1
    int expr;
}

/// A parsed program.
struct Program
{
    Expr[] exprs;
    int[] children;
    Decl[] decls;
}
