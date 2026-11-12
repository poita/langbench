/// @file error.hpp
/// @brief The exception type thrown for every statement-level failure.
#pragma once

#include <stdexcept>
#include <string>

namespace minisql {

/// Broad category of a failure.
enum class ErrorKind {
  Syntax,    ///< The text does not match the grammar (or has an invalid token).
  Semantic,  ///< Unknown/ambiguous names, misplaced aggregates, bad arity, ...
};

/// Thrown by the parser, binder and executor. A statement that throws has had
/// no effect on the database.
class Error : public std::runtime_error {
 public:
  Error(ErrorKind kind, const std::string& message)
      : std::runtime_error(message), kind_(kind) {}

  ErrorKind kind() const noexcept { return kind_; }

 private:
  ErrorKind kind_;
};

}  // namespace minisql
