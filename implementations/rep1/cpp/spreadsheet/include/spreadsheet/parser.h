// Formula parser (recursive descent).
#pragma once

#include <stdexcept>
#include <string_view>

#include "spreadsheet/formula.h"

namespace spreadsheet {

/// Thrown for text that is not a syntactically valid formula or cell content.
class ParseError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// Parses the expression part of a formula (the text after the leading `=`).
/// Throws ParseError on a syntax error.
Formula parse_formula(std::string_view expression);

}  // namespace spreadsheet
