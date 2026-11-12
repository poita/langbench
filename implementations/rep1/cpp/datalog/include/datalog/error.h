// Exception types thrown by the library.
#pragma once

#include <stdexcept>
#include <string>

namespace datalog {

/// Base class of all errors reported by the library.
class Error : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// The program text is not syntactically valid.
class ParseError : public Error {
 public:
  using Error::Error;
};

/// The program is syntactically valid but unsafe or not stratifiable.
class ProgramError : public Error {
 public:
  using Error::Error;
};

}  // namespace datalog
