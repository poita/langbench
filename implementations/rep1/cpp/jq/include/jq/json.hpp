// JSON parsing and compact serialisation.
#pragma once

#include <string>
#include <string_view>

#include "jq/error.hpp"
#include "jq/value.hpp"

namespace jq {

/// Parses exactly one RFC 8259 JSON value (surrounding whitespace allowed).
/// Object members keep document order. Throws JsonError on malformed input.
Value parse_json(std::string_view text);

/// Appends the compact JSON text of `v` to `out` (no whitespace, keys in
/// insertion order, only the mandatory string escapes plus U+007F).
void write_json(const Value& v, std::string& out);

/// Compact JSON text of `v`.
std::string to_json(const Value& v);

/// Appends the text of a number: integers without a decimal point, other
/// values in the shortest decimal form that round-trips.
void write_number(double d, std::string& out);

}  // namespace jq
