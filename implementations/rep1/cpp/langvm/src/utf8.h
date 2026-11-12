// Minimal UTF-8 <-> scalar-value conversion.
#pragma once

#include <string>
#include <string_view>

namespace langvm {

// Decodes UTF-8 into Unicode scalar values (invalid bytes become U+FFFD).
std::u32string decodeUtf8(std::string_view s);
// Appends the UTF-8 encoding of one scalar value.
void appendUtf8(std::string& out, char32_t c);
// Encodes a whole string of scalar values.
std::string encodeUtf8(std::u32string_view s);

}  // namespace langvm
