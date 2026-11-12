// Small integer / text helpers shared by every module.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace typeset {

using i64 = std::int64_t;

/// Floor division (rounds towards negative infinity); `b` must be positive.
inline i64 floorDiv(i64 a, i64 b) {
    i64 q = a / b;
    if (a % b != 0 && a < 0) --q;
    return q;
}

/// Scale a glyph-space quantity (thousandths of an em) to millipoints.
inline i64 scaleUnits(i64 units, i64 size) { return floorDiv(units * size, 1000); }

/// Greedy lowercase roman numeral; keeps adding `m` above 3999.
std::string toRoman(i64 n);

/// Bijective base-26 lowercase letters: 1 -> a, 26 -> z, 27 -> aa.
std::string toLetters(i64 n);

/// Decode UTF-8 into code points (invalid bytes are passed through as U+FFFD).
std::u32string utf8ToU32(std::string_view s);

/// Encode code points as UTF-8.
std::string u32ToUtf8(std::u32string_view s);

/// Append one code point to a UTF-8 string.
void appendUtf8(std::string& out, char32_t cp);

/// Number of code points in a UTF-8 string.
std::size_t utf8Length(std::string_view s);

/// Strip leading and trailing characters from `chars` (e.g. " \t").
std::string_view trim(std::string_view s, std::string_view chars = " \t");

}  // namespace typeset
