// Internal: filter text -> syntax tree.
#pragma once

#include <string_view>

#include "ast.hpp"

namespace jq::detail {

/// Parses a filter program. Throws jq::SyntaxError.
NodePtr parse_program(std::string_view text);

}  // namespace jq::detail
