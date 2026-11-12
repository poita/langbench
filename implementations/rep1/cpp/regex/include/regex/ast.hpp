#pragma once
/// \file ast.hpp
/// Syntax tree produced by the parser.

#include <memory>
#include <vector>

#include "regex/charset.hpp"

namespace regex {

enum class NodeKind {
  Literal,      ///< one specific byte (`ch`)
  Set,          ///< `.`, a class or a set escape (`set`)
  AssertBegin,  ///< `^`
  AssertEnd,    ///< `$`
  Concat,       ///< children matched in sequence (possibly none)
  Alternate,    ///< children tried left to right
  Group,        ///< capturing group `group` (1-based) around child 0
  Repeat        ///< greedy repetition of child 0, `min`..`max` times
};

/// Upper bound value meaning "unbounded" in Node::max.
inline constexpr int kUnbounded = -1;

struct Node {
  NodeKind kind = NodeKind::Concat;
  unsigned char ch = 0;  ///< Literal
  CharSet set;           ///< Set
  int group = 0;         ///< Group: 1-based index
  int min = 0;           ///< Repeat
  int max = 0;           ///< Repeat: kUnbounded or >= min
  std::vector<std::unique_ptr<Node>> children;

  explicit Node(NodeKind k) : kind(k) {}
};

using NodePtr = std::unique_ptr<Node>;

}  // namespace regex
