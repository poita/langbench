/// @file parser.hpp
/// @brief Recursive-descent parser for the SQL subset.
#pragma once

#include <string_view>
#include <vector>

#include "minisql/ast.hpp"
#include "minisql/lexer.hpp"

namespace minisql {

/// Parses the tokens `[begin, end)` (no terminating `;`) as one statement.
/// @throws Error (ErrorKind::Syntax) if they do not form exactly one statement.
Statement parse_statement(const Token* begin, const Token* end);

/// Convenience: tokenizes `sql` and parses it as a single statement. One
/// trailing `;` is allowed.
Statement parse_statement(std::string_view sql);

}  // namespace minisql
