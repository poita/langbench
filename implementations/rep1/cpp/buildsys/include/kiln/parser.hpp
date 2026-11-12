// KBL parser: logical lines to syntax tree.
#pragma once

#include <memory>
#include <string_view>

#include "kiln/ast.hpp"

namespace kiln {

/// Lexes and parses a build file. Throws `Error(E_PARSE)` with detail
/// `<file>:<line>` for the one error the specification selects.
std::shared_ptr<Program> parse_program(std::string_view source, std::string_view file);

}  // namespace kiln
