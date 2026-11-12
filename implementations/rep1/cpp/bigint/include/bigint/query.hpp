// Evaluation of one-line text queries such as "-7 / 2" or "2 ^ 10".
#pragma once

#include <iosfwd>
#include <string>
#include <string_view>

namespace bigint {

/// Evaluates one query `<a> <op> <b>` where op is one of `+ - * / % ^ cmp`.
///
/// Returns the canonical decimal result, `-1`/`0`/`1` for `cmp`, or the text
/// `error` for division/remainder by zero and negative exponents.
/// Throws std::invalid_argument if the line is not a well-formed query.
std::string evaluate_query(std::string_view line);

/// Reads queries from `in`, one per line (a missing final newline is fine,
/// empty lines are skipped), and writes one result line per query to `out`.
void run_queries(std::istream& in, std::ostream& out);

}  // namespace bigint
