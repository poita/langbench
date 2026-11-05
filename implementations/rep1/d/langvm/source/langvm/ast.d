/// The abstract syntax tree of Vellum modules.
module langvm.ast;

import langvm.diag;
import langvm.lexer : Tk;
import langvm.model;

/// A written type.
final class TypeExpr
{
    enum Kind : ubyte
    {
        path, list, map, tuple, fn,
    }

    Kind kind;
    Pos pos;
    /// Path types: optional qualifier, name, and the position of each.
    string qual;
    Pos qualPos;
    string name;
    Pos namePos;
    /// Type arguments (path), element (list), key/value (map), components (tuple), parameters (fn).
    TypeExpr[] args;
    bool hasArgs;
    /// Return type of a function type (null = Unit).
    TypeExpr ret;
}

// ---------------------------------------------------------------- expressions

/// Base class of expressions.
abstract class Expr
{
    /// Position of the first token (parentheses do not count).
    Pos pos;
    /// Type assigned by the checker.
    Type ty;
}

final class IntLit : Expr
{
    long v;
}

final class FloatLit : Expr
{
    double v;
}

final class StrLit : Expr
{
    dstring v;
}

final class CharLit : Expr
{
    dchar v;
}

final class BoolLit : Expr
{
    bool v;
}

final class SelfExpr : Expr
{
    LocalVar var;
}

/// A value path: `x` or `m::x`.
final class PathExpr : Expr
{
    string qual;
    Pos qualPos;
    string name;
    Pos namePos;

    enum Res : ubyte
    {
        none, local, func, builtin, variant, traitMethod,
    }

    Res res;
    LocalVar var;
    FuncDecl fn;
    Builtin builtin;
    DataDecl enumDecl;
    int variantIdx;
    TraitDecl trait;
    int methodIdx;
}

final class Unary : Expr
{
    Tk op;
    Expr e;
}

final class Binary : Expr
{
    Tk op;
    Expr l, r;
    Pos opPos;
}

final class Call : Expr
{
    Expr callee;
    Expr[] args;

    enum Kind : ubyte
    {
        indirect, func, builtin, variant, traitMethod,
    }

    Kind kind;
    FuncDecl fn;
    Builtin builtin;
    DataDecl enumDecl;
    int variantIdx;
    TraitDecl trait;
    int methodIdx;
}

final class MethodCall : Expr
{
    Expr recv;
    string name;
    Pos namePos;
    Expr[] args;
    TraitDecl trait;
    int methodIdx;
}

final class IndexExpr : Expr
{
    Expr base;
    Expr index;
}

final class FieldExpr : Expr
{
    Expr base;
    string name;
    Pos namePos;
    int fieldIdx;
}

/// One `name: expr` initialiser of a struct literal.
struct FieldInit
{
    string name;
    Pos pos;
    Expr value;
}

final class StructLit : Expr
{
    string qual;
    Pos qualPos;
    string name;
    Pos namePos;
    FieldInit[] inits;
    DataDecl decl;
    /// For each declared field: the index in `inits` providing it.
    int[] declToInit;
}

final class ListLit : Expr
{
    Expr[] elems;
}

final class MapLit : Expr
{
    Expr[] keys;
    Expr[] vals;
}

final class TupleLit : Expr
{
    Expr[] elems;
}

/// A lambda parameter.
struct LParam
{
    string name;
    Pos pos;
    TypeExpr te;
    LocalVar var;
}

final class Lambda : Expr
{
    LParam[] params;
    TypeExpr retTe;
    /// A [Block] or an arbitrary expression.
    Expr body;
    FuncInfo info;
}

final class IfExpr : Expr
{
    Expr cond;
    Block then;
    /// A [Block], an [IfExpr] or null.
    Expr els;
}

final class MatchArm
{
    Pat pat;
    Expr guard;
    Expr body;
}

final class MatchExpr : Expr
{
    Expr scrut;
    MatchArm[] arms;
}

final class Block : Expr
{
    Stmt[] stmts;
    Expr trailing;
}

// ---------------------------------------------------------------- statements

abstract class Stmt
{
    Pos pos;
}

final class LetStmt : Stmt
{
    Pat pat;
    TypeExpr te;
    Expr init;
}

final class VarStmt : Stmt
{
    string name;
    Pos namePos;
    TypeExpr te;
    Expr init;
    LocalVar var;
}

final class AssignStmt : Stmt
{
    Expr target;
    Expr value;
}

final class ExprStmt : Stmt
{
    Expr e;
}

final class ReturnStmt : Stmt
{
    Expr value;
}

final class WhileStmt : Stmt
{
    Expr cond;
    Block body;
}

final class ForStmt : Stmt
{
    Pat pat;
    Expr iter;
    /// Upper bound for range loops (null for sequence loops).
    Expr hi;
    Block body;
}

final class BreakStmt : Stmt
{
}

final class ContinueStmt : Stmt
{
}

// ---------------------------------------------------------------- patterns

abstract class Pat
{
    Pos pos;
}

final class WildPat : Pat
{
}

final class IdentPat : Pat
{
    string name;
    /// `P.{ f }` shorthand: always a binding.
    bool forceBind;
    LocalVar var; // when a binding
    DataDecl enumDecl; // when a 0-payload variant
    int variantIdx;
}

final class LitPat : Pat
{
    enum Kind : ubyte
    {
        int_, float_, str, char_, bool_,
    }

    Kind kind;
    long iv;
    double fv;
    dstring sv;
}

final class TuplePat : Pat
{
    Pat[] subs;
}

final class ListPat : Pat
{
    Pat[] subs;
    bool hasRest;
    string restName;
    Pos restPos;
    LocalVar restVar;
}

struct FieldPat
{
    string name;
    Pos pos;
    Pat sub;
    int fieldIdx;
}

final class StructPat : Pat
{
    string qual;
    Pos qualPos;
    string name;
    Pos namePos;
    FieldPat[] fields;
    bool dots;
    DataDecl decl;
}

final class VariantPat : Pat
{
    string qual;
    Pos qualPos;
    string name;
    Pos namePos;
    Pat[] subs;
    bool parens;
    DataDecl enumDecl;
    int variantIdx;
}

// ---------------------------------------------------------------- items

abstract class Item
{
    Pos pos;
    bool pub;
}

final class UseItem : Item
{
    string mod;
    Pos modPos;
    bool hasAlias;
    string alias_;
    Pos aliasPos;
}

final class TraitRefAst
{
    Pos pos;
    string qual;
    Pos qualPos;
    string name;
    Pos namePos;
}

final class GenParamAst
{
    string name;
    Pos pos;
    TraitRefAst[] bounds;
}

struct ParamAst
{
    string name;
    Pos pos;
    TypeExpr te;
}

final class FnItem : Item
{
    string name;
    Pos namePos;
    GenParamAst[] gen;
    ParamAst[] params;
    TypeExpr ret;
    Block body;
    FuncDecl decl;
}

final class StructItem : Item
{
    string name;
    Pos namePos;
    GenParamAst[] gen;
    ParamAst[] fields;
    DataDecl decl;
}

final class VariantAst
{
    string name;
    Pos pos;
    TypeExpr[] payload;
}

final class EnumItem : Item
{
    string name;
    Pos namePos;
    GenParamAst[] gen;
    VariantAst[] variants;
    DataDecl decl;
}

final class MethodAst
{
    Pos pos; // `fn`
    string name;
    Pos namePos;
    ParamAst[] params;
    TypeExpr ret;
    Block body; // null for a signature without default
}

final class TraitItem : Item
{
    string name;
    Pos namePos;
    MethodAst[] methods;
    TraitDecl decl;
}

final class ImplAst : Item
{
    GenParamAst[] gen;
    TraitRefAst trait;
    TypeExpr head;
    MethodAst[] methods;
    ImplDecl decl;
}

/// The parsed body of one module.
final class ModuleAst
{
    string name;
    Item[] items;
}
