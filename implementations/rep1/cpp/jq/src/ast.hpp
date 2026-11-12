// Syntax tree of a filter program (internal).
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "jq/value.hpp"

namespace jq::detail {

enum class NodeKind {
  Identity,
  Literal,
  Var,
  Neg,
  Pipe,
  Comma,
  Binary,
  And,
  Or,
  Index,    // a[b]       (a = target, b = index)
  Iterate,  // a[]
  Slice,    // a[b:c]     (b, c optional)
  Try,      // a?  (try semantics)
  Array,    // [a]        (a optional)
  Object,
  If,       // if a then b else c end (c optional => identity)
  As,       // a as $var | b
  Reduce,   // reduce a as $var (b; c)
  Call,
};

enum class BinOp { Add, Sub, Mul, Div, Mod, Eq, Ne, Lt, Le, Gt, Ge };

enum class Builtin {
  Empty, Error0, Error1, Not, Length, Keys, Has, Type, Add, Select, Map,
  Sort, SortBy, GroupBy, Unique, Reverse, Min, Max, ToString, ToNumber,
};

struct Node;
using NodePtr = std::unique_ptr<Node>;

struct ObjEntry {
  std::string literal_key;  // used when key == nullptr
  NodePtr key;              // computed key expression, or null
  NodePtr value;
};

struct Node {
  explicit Node(NodeKind k) : kind(k) {}
  NodeKind kind;
  BinOp op = BinOp::Add;
  Builtin builtin = Builtin::Empty;
  bool optional = false;  // Index/Iterate/Slice written with a trailing `?`
  int var = -1;           // interned variable id (Var, As, Reduce)
  Value literal;          // Literal
  NodePtr a, b, c;
  std::vector<NodePtr> args;       // Call arguments
  std::vector<ObjEntry> entries;   // Object
};

}  // namespace jq::detail
