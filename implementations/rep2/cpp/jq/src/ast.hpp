// Internal: the filter syntax tree.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "jq/value.hpp"

namespace jq::detail {

enum class Kind {
  Identity,
  Literal,
  Var,
  Neg,
  Pipe,
  Comma,
  Binary,
  And,
  Or,
  Index,
  Slice,
  Iterate,
  Try,
  Array,
  Object,
  If,
  As,
  Reduce,
  Call,
};

enum class BinOp { Add, Sub, Mul, Div, Mod, Eq, Ne, Lt, Le, Gt, Ge };

enum class Builtin {
  Empty,
  Error,
  Not,
  Length,
  Keys,
  Has,
  Type,
  Add,
  Select,
  Map,
  Sort,
  SortBy,
  GroupBy,
  Unique,
  Reverse,
  Min,
  Max,
  ToString,
  ToNumber,
};

struct Node;
using NodePtr = std::unique_ptr<Node>;

struct ObjEntry {
  NodePtr key;    // computes the key (a Literal string for plain keys)
  NodePtr value;  // computes the value
};

struct Node {
  Kind kind;
  Value lit;          // Literal
  std::string name;   // Var
  BinOp op{};         // Binary
  Builtin builtin{};  // Call
  bool opt = false;   // Index/Slice/Iterate: tolerant (`?` directly after)
  // Generic children. Layout by kind:
  //  Neg/Try/Array(body or null): a;  Pipe/Comma/And/Or/Binary: a, b
  //  Index: a=target, b=index;  Slice: a=target, b=from|null, c=to|null
  //  Iterate: a=target;  If: a=cond, b=then, c=else|null
  //  As: a=source, b=body;  Reduce: a=source, b=init, c=update
  //  Call: args
  NodePtr a, b, c;
  std::vector<NodePtr> args;
  std::vector<ObjEntry> entries;

  explicit Node(Kind k) : kind(k) {}
};

}  // namespace jq::detail
