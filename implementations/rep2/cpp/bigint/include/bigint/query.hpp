// Evaluation of one-line text queries: "<a> <op> <b>".
//
// This is the logic behind the command-line tool; it is part of the library so
// it can be tested and reused.
#pragma once

#include <string>
#include <string_view>

namespace bigint {

/// Evaluates a single query line (without the trailing newline), where op is
/// one of + - * / % ^ cmp, and returns the printable result: a canonical
/// decimal integer, "-1"/"0"/"1" for cmp, or "error" for division or remainder
/// by zero and for a negative exponent.
/// Throws ParseError if the line is not a well-formed query.
std::string evaluate_query(std::string_view line);

/// Evaluates every line of `input` (separated by '\n'; a final newline is
/// optional) and returns the results, one per line, each ending in '\n'.
std::string evaluate_queries(std::string_view input);

}  // namespace bigint
