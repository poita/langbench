#pragma once
/// \file parser.hpp
/// Recursive-descent parser producing a `Template` from source text.

#include <memory>
#include <string>
#include <string_view>

#include "jinjalite/ast.hpp"

namespace jinjalite {

/// Lexes, parses and filter-checks `source`.
/// Throws `Error(Syntax)` for any lexing/parsing problem, otherwise
/// `Error(Filter)` if an unknown filter name is used anywhere.
std::unique_ptr<Template> parse_template(std::string name, std::string_view source);

}  // namespace jinjalite
