#pragma once
/// \file error.hpp
/// The error kinds a command can fail with, and the exception that carries them.

#include <stdexcept>
#include <string>

namespace tessera {

enum class ErrorKind {
  Syntax,
  UnknownCommand,
  BadUtf8,
  IntRange,
  DupField,
  Depth,
  BadKey,
  BadPath,
  NotFound,
  NoField,
  NotObject,
  DocTooLarge,
  IndexKeyTooLong,
  IndexExists,
  IndexMissing,
  IndexLimit,
  TxnActive,
  NoTxn,
};

/// The spelling used in `results.txt` (`syntax`, `unknown-command`, ...).
const char* error_name(ErrorKind kind);

/// Thrown by the library when an operation fails. A failing operation never
/// modifies the database.
class Error : public std::runtime_error {
 public:
  explicit Error(ErrorKind kind) : std::runtime_error(error_name(kind)), kind_(kind) {}
  ErrorKind kind() const { return kind_; }

 private:
  ErrorKind kind_;
};

}  // namespace tessera
