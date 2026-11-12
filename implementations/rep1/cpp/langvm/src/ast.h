// Syntax tree of Vellum (SPEC.md section 4), plus the annotations the checker
// leaves on it for the bytecode compiler.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "lexer.h"

namespace langvm {

struct Type;  // semantic type (types.h)
struct Expr;
struct Pattern;
struct Block;
struct TypeExpr;
using ExprP = std::unique_ptr<Expr>;
using PatternP = std::unique_ptr<Pattern>;
using BlockP = std::unique_ptr<Block>;
using TypeExprP = std::unique_ptr<TypeExpr>;

// A local variable (parameter, let/var binding, pattern binding, self).
struct LocalVar {
  std::string name;
  Type* type = nullptr;
  bool isMut = false;
  int ownerFn = 0;  // id of the function/lambda that declares it
  int slot = -1;    // assigned by the compiler
};

// ---------------------------------------------------------------- types

struct TypeExpr {
  enum class K { List, Map, Tuple, Fn, Path };
  K kind = K::Path;
  Pos pos;
  // Path: optional qualifier and name.
  std::string qual;
  Pos qualPos;
  std::string name;
  Pos namePos;
  bool hasArgs = false;
  // List: [elem]; Map: [key, value]; Tuple: components; Fn: parameters;
  // Path: type arguments.
  std::vector<TypeExprP> args;
  TypeExprP ret;  // Fn only; null means Unit
};

struct TraitRef {
  Pos pos;  // first token
  std::string qual;
  Pos qualPos;
  std::string name;
  Pos namePos;
};

struct GenParam {
  std::string name;
  Pos pos;
  std::vector<TraitRef> bounds;
};

// ------------------------------------------------------------- patterns

struct FieldPat {
  std::string name;
  Pos pos;
  PatternP pat;  // null never: `P.{ f }` is parsed as a Bind pattern
  int fieldIdx = -1;
};

struct Pattern {
  enum class K { Wild, Int, Float, Str, Char, Bool, Tuple, List, Struct, Path, Bind };
  K kind = K::Wild;
  Pos pos;
  int64_t ival = 0;  // Int (already negated), Char
  double fval = 0;
  bool bval = false;
  std::u32string sval;
  // Path / Struct / Bind
  std::string qual;
  Pos qualPos;
  std::string name;
  Pos namePos;
  bool hasParens = false;
  std::vector<PatternP> subs;  // Tuple, List elements, Path arguments
  std::vector<FieldPat> fields;
  bool hasDots = false;  // Struct: trailing `..`
  bool hasRest = false;  // List: `..` or `..name`
  std::string restName;
  Pos restPos;
  // --- annotations
  LocalVar* var = nullptr;      // Bind; also the named list rest
  int decl = -1;                // Struct / variant: type declaration
  int variant = -1;             // variant index
};

// ----------------------------------------------------------- expressions

enum class EK {
  Int, Float, Str, Char, Bool, SelfRef, Path, StructLit, List, Map, Tuple, Lambda, If, Match,
  Unary, Binary, Call, Index, Field, MethodCall
};

enum class Op {
  Neg, Not, BitNot,
  Add, Sub, Mul, Div, Mod, Concat,
  BitAnd, BitOr, BitXor, Shl, Shr,
  Lt, Le, Gt, Ge, Eq, Ne, And, Or
};

struct FieldInit {
  std::string name;
  Pos pos;
  ExprP value;
  int fieldIdx = -1;
};

struct LParam {
  std::string name;
  Pos pos;
  TypeExprP type;  // optional
  LocalVar* var = nullptr;
};

struct Arm {
  PatternP pat;
  ExprP guard;
  BlockP body;  // a non-block arm body is wrapped into a block with only a tail
  Pos pos;      // position of the pattern
};

// How the checker resolved a call.
enum class CallKind { None, Func, Builtin, Variant, Indirect, Method };
// How the checker resolved a path expression.
enum class PathKind { None, Local, Variant0, Func, Builtin, VariantCtor, TraitMethod };

struct Expr {
  EK kind = EK::Int;
  Pos pos;
  int64_t ival = 0;  // Int, Char
  double fval = 0;
  bool bval = false;
  std::u32string sval;
  // Path / StructLit path / Field name / MethodCall name
  std::string qual;
  Pos qualPos;
  std::string name;
  Pos namePos;
  Op op = Op::Add;
  ExprP lhs, rhs;              // Unary: lhs; Binary; Index (lhs base, rhs index); Call callee = lhs
  std::vector<ExprP> args;     // Call/MethodCall args, List/Tuple elements, Map keys
  std::vector<ExprP> args2;    // Map values
  std::vector<FieldInit> fields;
  // Lambda
  std::vector<LParam> lparams;
  TypeExprP lret;
  BlockP body;
  // If
  ExprP cond;
  BlockP thenB, elseB;
  ExprP elseIf;
  // Match
  ExprP scrut;
  std::vector<Arm> arms;
  // --- annotations
  PathKind pathKind = PathKind::None;
  CallKind callKind = CallKind::None;
  LocalVar* var = nullptr;     // Path/SelfRef -> Local
  int id = -1;                 // function / builtin / struct decl / trait id
  int id2 = -1;                // variant index / method index
  bool isFloat = false;        // Unary Neg / arithmetic on Float
  std::vector<LocalVar*> captures;  // Lambda
  signed char divergesCache = -1;
};

// ------------------------------------------------------------ statements

struct Stmt {
  enum class K { Let, Var, Assign, Expr, Return, While, For, Break, Continue };
  K kind = K::Expr;
  Pos pos;
  PatternP pat;     // Let, For
  std::string name;  // Var
  Pos namePos;
  TypeExprP type;   // Let, Var
  ExprP expr;       // Let/Var init, Assign target, Expr, Return value, While cond, For sequence/lo
  ExprP expr2;      // Assign value, For range hi
  BlockP body;      // While, For
  LocalVar* var = nullptr;  // Var
  bool isRange = false;     // For
};
using StmtP = std::unique_ptr<Stmt>;

struct Block {
  Pos pos;  // the `{`
  std::vector<StmtP> stmts;
  ExprP tail;
  signed char divergesCache = -1;
};

// ----------------------------------------------------------------- items

struct Param {
  std::string name;
  Pos pos;
  TypeExprP type;
  LocalVar* var = nullptr;
};

struct FnDecl {
  Pos pos;  // `fn`
  bool pub = false;
  std::string name;
  Pos namePos;
  std::vector<GenParam> generics;
  bool hasSelf = false;
  std::vector<Param> params;  // excluding self
  TypeExprP ret;
  BlockP body;  // null for a trait method without default
  int funcId = -1;
  LocalVar* selfVar = nullptr;
};

struct FieldDecl {
  std::string name;
  Pos pos;
  TypeExprP type;
};

struct StructDecl {
  Pos pos;
  bool pub = false;
  std::string name;
  Pos namePos;
  std::vector<GenParam> generics;
  std::vector<FieldDecl> fields;
  int declId = -1;
};

struct VariantDecl {
  std::string name;
  Pos pos;
  std::vector<TypeExprP> payload;
};

struct EnumDecl {
  Pos pos;
  bool pub = false;
  std::string name;
  Pos namePos;
  std::vector<GenParam> generics;
  std::vector<VariantDecl> variants;
  int declId = -1;
};

struct TraitDecl {
  Pos pos;
  bool pub = false;
  std::string name;
  Pos namePos;
  std::vector<FnDecl> methods;
  int traitId = -1;
};

struct ImplDecl {
  Pos pos;
  std::vector<GenParam> generics;
  TraitRef trait;
  TypeExprP head;
  std::vector<FnDecl> methods;
  int implId = -1;
};

struct UseDecl {
  Pos pos;
  std::string module;
  Pos modPos;
  bool hasAlias = false;
  std::string alias;
  Pos aliasPos;
};

enum class ItemKind { Use, Fn, Struct, Enum, Trait, Impl };

struct Item {
  ItemKind kind;
  size_t index;  // into the matching vector of ModuleAst
};

struct ModuleAst {
  std::vector<Item> items;
  std::vector<std::unique_ptr<UseDecl>> uses;
  std::vector<std::unique_ptr<FnDecl>> fns;
  std::vector<std::unique_ptr<StructDecl>> structs;
  std::vector<std::unique_ptr<EnumDecl>> enums;
  std::vector<std::unique_ptr<TraitDecl>> traits;
  std::vector<std::unique_ptr<ImplDecl>> impls;
};

}  // namespace langvm
