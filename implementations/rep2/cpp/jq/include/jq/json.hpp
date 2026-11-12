// jq/json.hpp -- JSON text <-> Value.
//
// The parser accepts exactly one RFC 8259 value surrounded by optional
// whitespace. The serializer emits compact JSON (no spaces) with object
// members in insertion order.
#pragma once

#include <string>
#include <string_view>

#include "jq/error.hpp"
#include "jq/value.hpp"

namespace jq {

/// Parses `text` as a single JSON value. Throws JsonError on malformed input.
Value parse_json(std::string_view text);

/// Appends the compact JSON text of `v` to `out`.
///
/// Strings escape `"` `\\` and control characters (< U+0020 and U+007F);
/// everything else is raw UTF-8. Integral numbers print without a decimal
/// point; other numbers print in the shortest form that round-trips.
void write_json(const Value& v, std::string& out);

/// Compact JSON text of `v`.
std::string to_json(const Value& v);

/// Appends the text of a number as `write_json` would print it.
void write_number(double d, std::string& out);

}  // namespace jq
