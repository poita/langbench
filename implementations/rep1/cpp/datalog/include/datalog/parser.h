// Parser: source text -> Program.
#pragma once

#include <string_view>

#include "datalog/ast.h"

namespace datalog {

/// Parses a whole program. Throws ParseError (with a line number) when the
/// text is not syntactically valid. Safety and stratification are *not*
/// checked here; see analysis.h.
Program parse_program(std::string_view source);

}  // namespace datalog
