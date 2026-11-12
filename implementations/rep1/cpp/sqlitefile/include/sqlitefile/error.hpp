#pragma once
/// \file error.hpp
/// Exception types thrown by the library.

#include <stdexcept>

namespace sqlitefile {

/// Base class of every exception thrown by this library.
class Error : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// The database file (or a record, or a schema statement) is malformed or
/// uses a feature this reader does not support.
class FormatError : public Error {
 public:
  using Error::Error;
};

/// A query line is malformed or refers to something that does not exist.
class QueryError : public Error {
 public:
  using Error::Error;
};

}  // namespace sqlitefile
