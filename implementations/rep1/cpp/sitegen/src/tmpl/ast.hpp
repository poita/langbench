// Syntax tree of a parsed template. Internal.
#pragma once

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "sitegen/value.hpp"

namespace sitegen::tmpl {

enum class FilterId {
  Upper, Lower, Trim, Escape, Replace, Length, Int, Join, First, Last, Reverse, Sort, Default
};

enum class ExprKind {
  Literal,   // literal
  Name,      // sym
  List,      // args = elements
  Attr,      // args[0] = object, name = member
  Index,     // args[0] = object, args[1] = key
  Call,      // args[0] = callee, args[1..] = positional, kwargs
  Neg,       // args[0]
  Not,       // args[0]
  Binary,    // bop, args[0], args[1]
  And,       // args[0], args[1]
  Or,        // args[0], args[1]
  Compare,   // args = operands (n + 1), cmp_ops (n)
  Filter,    // filter, args[0] = input, args[1..] = arguments
  IsDefined  // args[0], negate
};

enum class BinOp { Add, Sub, Mul, Div, FloorDiv, Mod, Pow, Concat };
enum class CmpOp { Eq, Ne, Lt, Le, Gt, Ge, In, NotIn };

struct Expr;
using ExprPtr = std::unique_ptr<Expr>;

struct Expr {
  ExprKind kind = ExprKind::Literal;
  Value literal;
  int sym = -1;
  std::string name;
  BinOp bop = BinOp::Add;
  FilterId filter = FilterId::Upper;
  bool negate = false;
  std::vector<ExprPtr> args;
  std::vector<std::pair<std::string, ExprPtr>> kwargs;
  std::vector<CmpOp> cmp_ops;
};

struct Stmt;
using StmtPtr = std::unique_ptr<Stmt>;
using Body = std::vector<StmtPtr>;

enum class StmtKind { Text, Print, If, For, Set, Macro, Include, Extends, Block };

struct Param {
  int sym = -1;
  std::string name;
  ExprPtr default_value;  // may be null
};

struct Branch {
  ExprPtr condition;
  Body body;
};

struct Stmt {
  StmtKind kind = StmtKind::Text;
  std::string text;                 // Text; macro/block name
  ExprPtr expr;                     // Print, For (iterable), Set, Include, Extends
  int sym = -1;                     // For (loop variable), Set, Macro
  std::vector<Branch> branches;     // If
  Body body;                        // For, Macro, Block
  Body else_body;                   // If, For
  std::vector<Param> params;        // Macro
};

/// A parsed template.
struct Template {
  Body body;
  /// Every `block` tag of the template, by name, wherever it appears.
  std::unordered_map<std::string, const Stmt*> blocks;
  std::vector<std::string> block_order;
};

}  // namespace sitegen::tmpl
