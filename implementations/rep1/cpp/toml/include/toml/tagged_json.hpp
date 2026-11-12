// toml/tagged_json.hpp - the toml-test "tagged JSON" interchange format.
#pragma once

#include <stdexcept>
#include <string>
#include <string_view>

#include "toml/value.hpp"

namespace toml {

/// Thrown by `from_tagged_json` on malformed input.
class JsonError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// Serialises a tree as compact JSON with keys sorted by code point. Scalars
/// become {"type":...,"value":...} objects whose value is the canonical text.
std::string to_tagged_json(const Value& root);

/// Reads tagged JSON (any whitespace, any member order) into a tree. An
/// object with exactly the string members "type" (a valid type name) and
/// "value" is a scalar; every other object is a table.
Value from_tagged_json(std::string_view json);

}  // namespace toml
