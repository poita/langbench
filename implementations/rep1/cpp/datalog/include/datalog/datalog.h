// Umbrella header and one-call convenience API.
#pragma once

#include <string>
#include <string_view>

#include "datalog/analysis.h"
#include "datalog/ast.h"
#include "datalog/engine.h"
#include "datalog/error.h"
#include "datalog/parser.h"

namespace datalog {

/// Formats the answer to one query: the matching tuples as `p(v1, v2)` lines
/// followed by `-- N`.
std::string format_answer(const Atom& query, const std::vector<Tuple>& tuples);

/// Parses and evaluates `source` and returns the complete program output:
/// the formatted answers to all queries in order, or "error\n" if the
/// program is unsafe or not stratifiable. Throws ParseError on malformed text.
std::string run_program(std::string_view source);

}  // namespace datalog
