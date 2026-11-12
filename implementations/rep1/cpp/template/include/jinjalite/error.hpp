#pragma once
/// \file error.hpp
/// Error type thrown by every stage of the engine.

#include <stdexcept>
#include <string>

namespace jinjalite {

/// The five failure categories a template run can end in.
enum class ErrorKind {
  Syntax,     ///< template cannot be lexed or parsed
  Filter,     ///< template uses an unknown filter name
  Undefined,  ///< forbidden use of the undefined value
  Template,   ///< include/extends of a template that does not exist
  Type,       ///< operand or argument of the wrong kind, bad arity, ...
};

/// The lowercase name of a kind (`"syntax"`, `"filter"`, ...), as printed by
/// the command-line tool after `error: `.
const char* to_string(ErrorKind kind) noexcept;

/// The single exception type the engine throws for template errors.
class Error : public std::runtime_error {
 public:
  Error(ErrorKind kind, const std::string& detail)
      : std::runtime_error(std::string(to_string(kind)) + ": " + detail),
        kind_(kind) {}

  ErrorKind kind() const noexcept { return kind_; }

 private:
  ErrorKind kind_;
};

}  // namespace jinjalite
