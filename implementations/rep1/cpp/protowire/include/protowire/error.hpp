// Exception types thrown by the protowire library.
#pragma once

#include <stdexcept>
#include <string>

namespace protowire {

/// Base class of every exception thrown by protowire.
class Error : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// The schema text is malformed or refers to an unknown type.
class SchemaError : public Error {
 public:
  using Error::Error;
};

/// A byte string is not a valid encoding of the requested message.
class WireError : public Error {
 public:
  using Error::Error;
};

/// A text-form message is malformed or does not fit the schema.
class TextError : public Error {
 public:
  using Error::Error;
};

/// Hex input is malformed (odd length, non-lowercase-hex character).
class HexError : public Error {
 public:
  using Error::Error;
};

}  // namespace protowire
