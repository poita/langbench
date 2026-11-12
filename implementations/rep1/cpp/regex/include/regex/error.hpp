#pragma once
/// \file error.hpp
/// Exception types thrown by the library.

#include <cstddef>
#include <stdexcept>
#include <string>

namespace regex {

/// Base class of every exception thrown by this library.
class Error : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// The pattern is not valid in the supported syntax.
class ParseError : public Error {
 public:
  ParseError(const std::string& message, std::size_t position)
      : Error(message + " (at offset " + std::to_string(position) + ")"),
        position_(position) {}

  /// Offset in the pattern at which the problem was detected.
  std::size_t position() const noexcept { return position_; }

 private:
  std::size_t position_;
};

}  // namespace regex
