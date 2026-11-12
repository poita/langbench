// Filter lexer + recursive-descent parser (internal).
#pragma once

#include <string>
#include <string_view>

#include "ast.hpp"

namespace jq::detail {

struct Program {
  NodePtr root;
  int var_count = 0;
};

/// Parses a filter. Throws jq::ParseError on syntax errors / unknown builtins.
Program parse_program(std::string_view source);

}  // namespace jq::detail
