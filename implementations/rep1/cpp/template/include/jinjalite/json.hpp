#pragma once
/// \file json.hpp
/// A small RFC 8259 JSON parser producing template values.
///
/// Numbers without a fraction or exponent become integers, others floats;
/// objects become insertion-ordered dicts.

#include <stdexcept>
#include <string_view>

#include "jinjalite/value.hpp"

namespace jinjalite {

/// Thrown for malformed JSON.
class JsonError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// Parses one JSON document (surrounding whitespace allowed).
Value parse_json(std::string_view text);

}  // namespace jinjalite
