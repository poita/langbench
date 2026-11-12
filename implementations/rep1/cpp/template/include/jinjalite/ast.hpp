#pragma once
/// \file ast.hpp
/// Syntax tree of a parsed template.

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "jinjalite/filters.hpp"
#include "jinjalite/ops.hpp"
#include "jinjalite/value.hpp"

namespace jinjalite {

// ---- Expressions -----------------------------------------------------------

enum class ExprKind { Literal, Name, List, Negate, Not, And, Or, Binary, Compare, Filter, IsDefined, Get, Call };

struct Expr {
  explicit Expr(ExprKind k) : kind(k) {}
  virtual ~Expr() = default;
  const ExprKind kind;
};
using ExprPtr = std::unique_ptr<Expr>;

struct LiteralExpr : Expr {
  explicit LiteralExpr(Value v) : Expr(ExprKind::Literal), value(std::move(v)) {}
  Value value;
};

struct NameExpr : Expr {
  explicit NameExpr(std::string n) : Expr(ExprKind::Name), name(std::move(n)) {}
  std::string name;
};

struct ListExpr : Expr {
  ListExpr() : Expr(ExprKind::List) {}
  std::vector<ExprPtr> items;
};

/// `-operand` or `not operand` (kind Negate / Not).
struct UnaryExpr : Expr {
  UnaryExpr(ExprKind k, ExprPtr o) : Expr(k), operand(std::move(o)) {}
  ExprPtr operand;
};

/// `lhs and rhs` / `lhs or rhs` (kind And / Or); short-circuiting, returning
/// the deciding operand.
struct LogicalExpr : Expr {
  LogicalExpr(ExprKind k, ExprPtr l, ExprPtr r) : Expr(k), lhs(std::move(l)), rhs(std::move(r)) {}
  ExprPtr lhs, rhs;
};

struct BinaryExpr : Expr {
  BinaryExpr(BinaryOp o, ExprPtr l, ExprPtr r) : Expr(ExprKind::Binary), op(o), lhs(std::move(l)), rhs(std::move(r)) {}
  BinaryOp op;
  ExprPtr lhs, rhs;
};

/// A comparison chain `first op1 e1 op2 e2 ...`.
struct CompareExpr : Expr {
  CompareExpr() : Expr(ExprKind::Compare) {}
  ExprPtr first;
  std::vector<std::pair<CompareOp, ExprPtr>> rest;
};

struct FilterExpr : Expr {
  FilterExpr() : Expr(ExprKind::Filter) {}
  ExprPtr input;
  const FilterInfo* filter = nullptr;
  std::vector<ExprPtr> args;
};

/// `operand is defined` / `operand is not defined`.
struct IsDefinedExpr : Expr {
  IsDefinedExpr(ExprPtr o, bool neg) : Expr(ExprKind::IsDefined), operand(std::move(o)), negated(neg) {}
  ExprPtr operand;
  bool negated;
};

/// `object.name` (key is a string literal) or `object[key]`.
struct GetExpr : Expr {
  GetExpr(ExprPtr o, ExprPtr k) : Expr(ExprKind::Get), object(std::move(o)), key(std::move(k)) {}
  ExprPtr object, key;
};

struct CallExpr : Expr {
  CallExpr() : Expr(ExprKind::Call) {}
  ExprPtr callee;
  std::vector<ExprPtr> args;
  std::vector<std::pair<std::string, ExprPtr>> kwargs;
};

// ---- Statements ------------------------------------------------------------

enum class StmtKind { Text, Print, If, For, Set, Macro, Include, Extends, Block };

struct Stmt {
  explicit Stmt(StmtKind k) : kind(k) {}
  virtual ~Stmt() = default;
  const StmtKind kind;
};
using StmtPtr = std::unique_ptr<Stmt>;
using Body = std::vector<StmtPtr>;

struct TextStmt : Stmt {
  explicit TextStmt(std::string t) : Stmt(StmtKind::Text), text(std::move(t)) {}
  std::string text;
};

struct PrintStmt : Stmt {
  explicit PrintStmt(ExprPtr e) : Stmt(StmtKind::Print), expr(std::move(e)) {}
  ExprPtr expr;
};

struct IfStmt : Stmt {
  IfStmt() : Stmt(StmtKind::If) {}
  /// The `if` and each `elif` branch, in order.
  std::vector<std::pair<ExprPtr, Body>> branches;
  Body else_body;
};

struct ForStmt : Stmt {
  ForStmt() : Stmt(StmtKind::For) {}
  std::string var;
  ExprPtr iterable;
  Body body;
  Body else_body;
};

struct SetStmt : Stmt {
  SetStmt() : Stmt(StmtKind::Set) {}
  std::string name;
  ExprPtr value;
};

struct MacroParam {
  std::string name;
  ExprPtr default_value;  ///< null if the parameter has no default
};

struct MacroStmt : Stmt {
  MacroStmt() : Stmt(StmtKind::Macro) {}
  std::string name;
  std::vector<MacroParam> params;
  Body body;
};

struct IncludeStmt : Stmt {
  explicit IncludeStmt(ExprPtr e) : Stmt(StmtKind::Include), name(std::move(e)) {}
  ExprPtr name;
};

struct ExtendsStmt : Stmt {
  explicit ExtendsStmt(ExprPtr e) : Stmt(StmtKind::Extends), name(std::move(e)) {}
  ExprPtr name;
};

struct BlockStmt : Stmt {
  BlockStmt() : Stmt(StmtKind::Block) {}
  std::string name;
  Body body;
};

/// A fully parsed, filter-checked template.
struct Template {
  std::string name;
  Body body;
  /// Every `block` in the template (static block table), in source order.
  std::vector<const BlockStmt*> blocks;
};

}  // namespace jinjalite
