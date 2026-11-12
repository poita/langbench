/// @file text.hpp
/// Small UTF-8 and string helpers shared by the library's modules.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>

namespace sitegen::text {

/// Appends the UTF-8 encoding of the Unicode scalar value `cp` to `out`.
void append_utf8(std::string& out, char32_t cp);

/// Number of code points in the UTF-8 string `s`.
std::size_t utf8_length(std::string_view s);

/// Length in bytes of the UTF-8 sequence that starts with the lead byte `c`
/// (1 for malformed lead bytes, so scanning always makes progress).
std::size_t utf8_sequence_length(unsigned char c);

/// Maps `A`-`Z` to `a`-`z`; every other byte is unchanged.
std::string ascii_lower(std::string_view s);

/// Maps `a`-`z` to `A`-`Z`; every other byte is unchanged.
std::string ascii_upper(std::string_view s);

/// The whitespace of the template language: space, TAB, LF, CR, FF, VT.
inline bool is_template_space(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

}  // namespace sitegen::text
