// Canonical serialization of a Value.
#pragma once

#include <string>

#include "jsoncanon/value.hpp"

namespace jsoncanon {

/// Appends the canonical form of `value` to `out`:
///  - no whitespace outside strings;
///  - object members sorted by key in UTF-16 code unit order, duplicate keys
///    collapsed to the last occurrence;
///  - strings escape only `"`, `\`, and U+0000..U+001F (short forms for
///    \b \f \n \r \t, otherwise lowercase \u00xx); everything else is raw UTF-8;
///  - numbers are written from their stored text.
///
/// Output is written straight into `out` (no per-subtree temporaries), so the
/// cost is linear in the output plus O(m log m) key comparisons per object.
/// Recursion depth equals the nesting depth of `value`.
void serialize(const Value& value, std::string& out);

/// Convenience wrapper returning the canonical form as a new string.
std::string serialize(const Value& value);

/// Appends `s` as a quoted, escaped JSON string.
void write_string(std::string_view s, std::string& out);

}  // namespace jsoncanon
