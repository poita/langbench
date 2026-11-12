// Text -> Program.
#pragma once

#include <stdexcept>
#include <string>
#include <string_view>

#include "datalog/ast.h"

namespace datalog {

/// Thrown on syntactically malformed input.
class ParseError : public std::runtime_error {
 public:
  ParseError(const std::string& message, int line)
      : std::runtime_error("line " + std::to_string(line) + ": " + message),
        line_(line) {}
  int line() const { return line_; }

 private:
  int line_;
};

/// Parses a whole program (facts, rules and queries). `%` starts a comment
/// that runs to the end of the line.
Program parse_program(std::string_view source);

}  // namespace datalog
