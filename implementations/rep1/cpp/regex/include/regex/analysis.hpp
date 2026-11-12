#pragma once
/// \file analysis.hpp
/// Static analysis of a syntax tree, used to speed up the search for a start
/// position without changing which match is found.

#include "regex/ast.hpp"

namespace regex {

struct StartInfo {
  /// Bytes that can be the first character consumed by a match.
  CharSet first;
  /// True if the pattern can match without consuming a character (then every
  /// start position, including the end of the subject, must be tried).
  bool nullable = true;
  /// True if every match must begin at subject offset 0.
  bool anchored = false;
};

StartInfo analyze_start(const Node& root);

/// True if \p node can succeed without consuming any character.
bool can_match_empty(const Node& node);

}  // namespace regex
