// Syntax tree produced by the parser.
#pragma once

#include <cstddef>
#include <memory>
#include <vector>

#include "rx/charset.hpp"

namespace rx {

enum class NodeKind {
  Empty,      ///< matches the empty string
  Literal,    ///< one specific character (`ch`)
  Any,        ///< `.`
  Set,        ///< character class or class escape (`set`)
  Bol,        ///< `^`
  Eol,        ///< `$`
  Concat,     ///< children matched in sequence (>= 2 children)
  Alternate,  ///< ordered choice between children (>= 2 children)
  Group,      ///< capturing group `group` around children[0]
  Repeat,     ///< children[0] repeated min..max times, greedily
};

struct Node {
  /// `max` value of a Repeat that has no upper bound.
  static constexpr int kUnbounded = -1;

  NodeKind kind = NodeKind::Empty;
  unsigned char ch = 0;                        ///< Literal
  CharSet set;                                 ///< Set
  std::size_t group = 0;                       ///< Group: 1-based index
  int min = 0;                                 ///< Repeat
  int max = 0;                                 ///< Repeat (kUnbounded for none)
  bool nullable = false;                       ///< may match without consuming input
  std::vector<std::unique_ptr<Node>> children;

  explicit Node(NodeKind k) : kind(k) {}
};

/// Result of parsing a pattern.
struct ParsedPattern {
  std::unique_ptr<Node> root;
  std::size_t group_count = 0;
};

}  // namespace rx
