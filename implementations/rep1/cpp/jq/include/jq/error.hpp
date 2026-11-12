// Exception types thrown by the jq library.
#pragma once

#include <stdexcept>
#include <string>

namespace jq {

/// Base class of every exception thrown by this library.
class Error : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// A JSON document could not be parsed.
class JsonError : public Error {
 public:
  using Error::Error;
};

/// A filter program has a syntax error (or calls an unknown builtin).
class ParseError : public Error {
 public:
  using Error::Error;
};

/// Evaluating a filter raised an error (a type error, `error`, ...).
class RuntimeError : public Error {
 public:
  using Error::Error;
};

}  // namespace jq
