/// The syntax tree produced by the parser (SPEC.md section 4).
///
/// Nodes also carry a few fields (marked "set by the checker") that the type
/// checker fills in so that the bytecode compiler never has to look a name up
/// again (APPROACH.md, rule 2).
module langvm.ast;

import langvm.diag : Pos;
import langvm.types;

// ---------------------------------------------------------------- types

/// The shape of a written type.
enum TyK
{
    list, /// `[T]`
    map, /// `#[K: V]`
    tuple, /// `(A, B, ...)`
    fn, /// `fn(A, B) -> R`
    path, /// `Name`, `mod::Name`, optionally with `<args>`
}

/// A type as written in the source.
final class TypeExpr
{
    TyK kind;
    /// Position of the first token.
    Pos pos;
    /// list: `[elem]`; map: `[key, value]`; tuple: components; fn: parameters;
    /// path: type arguments.
    TypeExpr[] args;
    /// fn: the return type, or null for `Unit`.
    TypeExpr ret;
    /// path: the optional module qualifier and the name, with positions.
    string qual;
    Pos qualPos;
    string name;
    Pos namePos;
}

// ---------------------------------------------------------------- patterns

/// The shape of a pattern.
enum PatK
{
    wild, bind, int_, float_, str, char_, bool_, tuple, list, struct_, variant,
}

/// One `field` or `field: pattern` entry of a struct pattern.
struct FieldPat
{
    string name;
    Pos pos;
    /// The sub-pattern, or null for the shorthand `field`.
    Pattern pat;
    /// Set by the checker: index of the field in the struct declaration.
    int fieldIdx = -1;
    /// Set by the checker for the shorthand form: the variable it binds.
    LocalVar var;
}

/// A pattern.
final class Pattern
{
    PatK kind;
    Pos pos;
    /// int_ (already negated for `-int`) and char_ literals; bool_ uses 0/1.
    long ival;
    double fval;
    /// str literal.
    dstring sval;
    /// bind: the variable name.
    string name;
    /// tuple / variant payload patterns / list element patterns.
    Pattern[] subs;
    /// list: a trailing `..` or `..name`.
    bool hasRest;
    string restName;
    Pos restPos;
    /// variant / struct: the (possibly qualified) path.
    string qual;
    Pos qualPos;
    string cname;
    Pos cnamePos;
    bool hasParens;
    /// struct: the field patterns and a trailing `..`.
    FieldPat[] fields;
    bool structRest;

    // ---- set by the checker
    /// bind (and list rest): the variable.
    LocalVar var;
    LocalVar restVar;
    /// variant: the resolved variant.
    VariantInfo variant;
    /// struct: the resolved declaration.
    TypeDecl decl;
}

// ---------------------------------------------------------------- expressions

/// The shape of an expression.
enum EK
{
    int_, float_, str, char_, bool_, self_, path, structLit, tuple, list, map, lambda,
    if_, match, block, unary, binary, call, method, index, field,
}

/// An expression.
class Expr
{
    EK kind;
    /// Position of the first token (parentheses do not count).
    Pos pos;

    this(EK kind, Pos pos)
    {
        this.kind = kind;
        this.pos = pos;
    }
}

/// A literal: `int_`, `float_`, `str`, `char_` or `bool_`.
final class LitExpr : Expr
{
    long ival;
    double fval;
    dstring sval;

    this(EK kind, Pos pos)
    {
        super(kind, pos);
    }
}

/// `self`.
final class SelfExpr : Expr
{
    /// Set by the checker.
    LocalVar var;

    this(Pos pos)
    {
        super(EK.self_, pos);
    }
}

/// What a value path resolved to (set by the checker).
enum ResK
{
    none, local, fn, variant, methodPath,
}

/// `name` or `qual::name` in value position.
final class PathExpr : Expr
{
    string qual;
    Pos qualPos;
    string name;
    Pos namePos;

    // ---- set by the checker
    ResK res;
    LocalVar var;
    FnInfo fn;
    VariantInfo variant;
    TraitInfo trait;
    int methodIdx;

    this(Pos pos)
    {
        super(EK.path, pos);
    }
}

/// One `name: expr` entry of a struct literal.
struct FieldInit
{
    string name;
    Pos pos;
    Expr value;
}

/// `Path.{ f: e, ... }`.
final class StructLitExpr : Expr
{
    string qual;
    Pos qualPos;
    string name;
    Pos namePos;
    FieldInit[] inits;
    /// Set by the checker.
    TypeDecl decl;
    /// Set by the checker: for each written initialiser, its field index.
    int[] fieldOf;

    this(Pos pos)
    {
        super(EK.structLit, pos);
    }
}

/// `(a, b, ...)`, `[a, b, ...]` (list) or `#[k: v, ...]` (map; `elems` holds
/// key, value, key, value, ...).
final class SeqExpr : Expr
{
    Expr[] elems;

    this(EK kind, Pos pos)
    {
        super(kind, pos);
    }
}

/// A lambda parameter.
struct LParam
{
    string name;
    Pos pos;
    TypeExpr ann;
}

/// `|a, b| body` or `|| body`.
final class LambdaExpr : Expr
{
    LParam[] params;
    TypeExpr retAnn;
    /// A `BlockExpr` or any other expression.
    Expr body;
    // ---- set by the checker
    FuncCtx ctx;
    LocalVar[] paramVars;

    this(Pos pos)
    {
        super(EK.lambda, pos);
    }
}

/// `if c { } else { }`.
final class IfExpr : Expr
{
    Expr cond;
    BlockExpr then;
    /// A `BlockExpr`, an `IfExpr` or null.
    Expr else_;

    this(Pos pos)
    {
        super(EK.if_, pos);
    }
}

/// One arm of a `match`.
struct Arm
{
    Pattern pat;
    Expr guard;
    Expr body;
}

/// `match s { arms }`.
final class MatchExpr : Expr
{
    Expr scrut;
    Arm[] arms;

    this(Pos pos)
    {
        super(EK.match, pos);
    }
}

/// `{ stmts; tail }`.
final class BlockExpr : Expr
{
    Stmt[] stmts;
    /// The trailing expression, or null.
    Expr tail;

    this(Pos pos)
    {
        super(EK.block, pos);
    }
}

/// Prefix operators and binary operators.
enum Operator
{
    neg, not, bnot,
    add, sub, mul, div, rem, concat, band, bor, bxor, shl, shr,
    lt, le, gt, ge, eq, ne, and, or,
}

/// `-e`, `!e`, `~e`.
final class UnaryExpr : Expr
{
    Operator op;
    Expr operand;
    /// Set by the checker: the operand is a `Float`.
    bool isFloat;

    this(Pos pos, Operator op, Expr operand)
    {
        super(EK.unary, pos);
        this.op = op;
        this.operand = operand;
    }
}

/// `l op r`.
final class BinaryExpr : Expr
{
    Operator op;
    Expr left, right;
    /// Position of the operator token.
    Pos opPos;
    /// Set by the checker: arithmetic on `Float`; `++` on `Str` (otherwise a list).
    bool isFloat;
    bool isStr;

    this(Pos pos, Operator op, Expr left, Expr right)
    {
        super(EK.binary, pos);
        this.op = op;
        this.left = left;
        this.right = right;
    }
}

/// How a call was resolved (set by the checker).
enum CallK
{
    none, direct, builtin, variant, trait, indirect,
}

/// `callee(args)`.
final class CallExpr : Expr
{
    Expr callee;
    Expr[] args;
    // ---- set by the checker
    CallK ck;
    FnInfo fn;
    VariantInfo variant;
    TraitInfo trait;
    int methodIdx;

    this(Pos pos, Expr callee, Expr[] args)
    {
        super(EK.call, pos);
        this.callee = callee;
        this.args = args;
    }
}

/// `recv.name(args)`.
final class MethodExpr : Expr
{
    Expr recv;
    string name;
    Pos namePos;
    Expr[] args;
    // ---- set by the checker
    TraitInfo trait;
    int methodIdx;

    this(Pos pos, Expr recv, string name, Pos namePos, Expr[] args)
    {
        super(EK.method, pos);
        this.recv = recv;
        this.name = name;
        this.namePos = namePos;
        this.args = args;
    }
}

/// `obj[idx]`.
final class IndexExpr : Expr
{
    Expr obj, idx;

    this(Pos pos, Expr obj, Expr idx)
    {
        super(EK.index, pos);
        this.obj = obj;
        this.idx = idx;
    }
}

/// `obj.name`.
final class FieldExpr : Expr
{
    Expr obj;
    string name;
    Pos namePos;
    /// Set by the checker.
    int fieldIdx;

    this(Pos pos, Expr obj, string name, Pos namePos)
    {
        super(EK.field, pos);
        this.obj = obj;
        this.name = name;
        this.namePos = namePos;
    }
}

// ---------------------------------------------------------------- statements

/// The shape of a statement.
enum SK
{
    let_, var_, assign, expr, while_, for_, return_, break_, continue_,
}

/// A statement. Which fields are used depends on `kind`:
///
/// - `let_`: `pat`, `ann`, `expr`
/// - `var_`: `name`, `namePos`, `ann`, `expr`
/// - `assign`: `target`, `expr`
/// - `expr`: `expr`
/// - `while_`: `expr` (the condition), `body`
/// - `for_`: `pat`, `expr` (the sequence or range start), `hi` (range end or null), `body`
/// - `return_`: `expr` (or null)
final class Stmt
{
    SK kind;
    Pos pos;
    Pattern pat;
    string name;
    Pos namePos;
    TypeExpr ann;
    Expr expr;
    Expr target;
    Expr hi;
    BlockExpr body;
    // ---- set by the checker
    /// var_: the variable. assign (to an identifier): the variable.
    LocalVar var;
    /// for_: 0 = list, 1 = string, 2 = range.
    int forKind;

    this(SK kind, Pos pos)
    {
        this.kind = kind;
        this.pos = pos;
    }
}

// ---------------------------------------------------------------- items

/// The shape of an item.
enum IK
{
    use, fn, struct_, enum_, trait, impl,
}

/// A top-level item.
class Item
{
    IK kind;
    /// Position of the `use`/`fn`/`struct`/`enum`/`trait`/`impl` keyword.
    Pos pos;

    this(IK kind, Pos pos)
    {
        this.kind = kind;
        this.pos = pos;
    }
}

/// `use m;` / `use m as k;`.
final class UseItem : Item
{
    string mod;
    Pos modPos;
    string alias_;
    Pos aliasPos;

    this(Pos pos)
    {
        super(IK.use, pos);
    }
}

/// A reference to a trait: `Name` or `mod::Name`.
struct TraitRef
{
    string qual;
    Pos qualPos;
    string name;
    /// Position of the first token.
    Pos pos;
    Pos namePos;
}

/// A generic parameter with its bounds.
struct GenParam
{
    string name;
    Pos pos;
    TraitRef[] bounds;
}

/// A function or method parameter.
struct Param
{
    string name;
    Pos pos;
    TypeExpr type;
}

/// A function, trait method or impl method.
final class FnDecl : Item
{
    bool pub;
    string name;
    Pos namePos;
    GenParam[] gparams;
    /// Parameters, not counting `self` for methods.
    Param[] params;
    bool hasSelf;
    /// Null means `Unit`.
    TypeExpr ret;
    /// Null for a trait method without a default body.
    BlockExpr body;
    // ---- set by the checker
    FnInfo info;
    FuncCtx ctx;
    LocalVar[] paramVars;

    this(Pos pos)
    {
        super(IK.fn, pos);
    }
}

/// A field of a struct.
struct FieldDecl
{
    string name;
    Pos pos;
    TypeExpr type;
}

/// `struct Name<T> { fields }`.
final class StructDecl : Item
{
    bool pub;
    string name;
    Pos namePos;
    GenParam[] gparams;
    FieldDecl[] fields;
    TypeDecl info;

    this(Pos pos)
    {
        super(IK.struct_, pos);
    }
}

/// A variant of an enum.
struct VariantDecl
{
    string name;
    Pos pos;
    TypeExpr[] payload;
}

/// `enum Name<T> { variants }`.
final class EnumDecl : Item
{
    bool pub;
    string name;
    Pos namePos;
    GenParam[] gparams;
    VariantDecl[] variants;
    TypeDecl info;

    this(Pos pos)
    {
        super(IK.enum_, pos);
    }
}

/// `trait Name { method signatures }`.
final class TraitDecl : Item
{
    bool pub;
    string name;
    Pos namePos;
    FnDecl[] methods;
    TraitInfo info;

    this(Pos pos)
    {
        super(IK.trait, pos);
    }
}

/// `impl<T> Trait for Head { methods }`.
final class ImplDecl : Item
{
    GenParam[] gparams;
    TraitRef trait;
    TypeExpr head;
    FnDecl[] methods;
    ImplInfo info;

    this(Pos pos)
    {
        super(IK.impl, pos);
    }
}
