/// \file errors.hpp
/// Error categories raised while reading, analysing and evaluating programs.
#pragma once

#include <stdexcept>
#include <string>

namespace scheme {

/// The runtime error categories of the language. `SyntaxError` is not part of
/// the language contract: it reports malformed programs.
enum class ErrorKind {
  UnboundVariable,
  TypeError,
  ArityError,
  DivisionByZero,
  UserError,
  SyntaxError
};

/// The category name as printed after `error: ` (e.g. "type-error").
const char* error_name(ErrorKind kind);

/// Exception thrown for every Scheme-level error.
class SchemeError : public std::runtime_error {
 public:
  explicit SchemeError(ErrorKind kind, const std::string& detail = std::string())
      : std::runtime_error(detail.empty() ? std::string(error_name(kind)) : detail),
        kind_(kind) {}
  ErrorKind kind() const noexcept { return kind_; }

 private:
  ErrorKind kind_;
};

}  // namespace scheme
