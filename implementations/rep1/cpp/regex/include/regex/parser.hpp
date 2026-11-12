#pragma once
/// \file parser.hpp
/// Recursive-descent parser for the supported pattern syntax.

#include <string_view>

#include "regex/ast.hpp"
#include "regex/error.hpp"

namespace regex {

/// Largest `n`/`m` accepted inside a `{n,m}` quantifier.
inline constexpr int kMaxRepeatBound = 1000;

struct ParseResult {
  NodePtr root;
  int group_count = 0;
};

/// Parses \p pattern. Throws ParseError if it is not valid.
ParseResult parse(std::string_view pattern);

}  // namespace regex
