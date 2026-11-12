// Error types thrown by the rx library.
#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>

namespace rx {

/// Base class of every exception thrown by the library for bad input.
class Error : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// A pattern is syntactically invalid (or exceeds an implementation limit).
class ParseError : public Error {
 public:
  ParseError(const std::string& message, std::size_t offset)
      : Error(message + " at offset " + std::to_string(offset)), offset_(offset) {}

  /// Offset in the pattern at which the problem was detected.
  std::size_t offset() const noexcept { return offset_; }

 private:
  std::size_t offset_;
};

}  // namespace rx
