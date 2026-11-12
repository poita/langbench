// jq/error.hpp -- exception types thrown by the library.
#pragma once

#include <stdexcept>
#include <string>

namespace jq {

/// Thrown when JSON text cannot be parsed.
class JsonError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// Thrown when a filter program cannot be parsed.
class SyntaxError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// Thrown by Filter::run_all when evaluation raises an error.
class EvalError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

}  // namespace jq
