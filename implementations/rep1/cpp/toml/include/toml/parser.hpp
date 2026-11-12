// toml/parser.hpp - TOML 1.0.0 text -> Value tree.
#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>
#include <string_view>

#include "toml/value.hpp"

namespace toml {

/// Thrown when a document is not valid TOML 1.0.0.
class ParseError : public std::runtime_error {
 public:
  ParseError(const std::string& message, std::size_t line, std::size_t column)
      : std::runtime_error(message + " (line " + std::to_string(line) + ", column " +
                           std::to_string(column) + ")"),
        line_(line),
        column_(column) {}
  std::size_t line() const { return line_; }      ///< 1-based
  std::size_t column() const { return column_; }  ///< 1-based, in bytes

 private:
  std::size_t line_, column_;
};

/// Parses a complete TOML document. The root of the result is a table.
/// Throws `ParseError` if the document is invalid.
Value parse(std::string_view document);

}  // namespace toml
