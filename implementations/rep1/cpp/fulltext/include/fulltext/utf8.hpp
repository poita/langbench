/// @file utf8.hpp
/// Minimal UTF-8 helpers shared by the analyser, query lexer and snippet code.
///
/// All text in the engine is kept as UTF-8 `std::string`s and addressed by
/// *byte* offsets; code points are decoded on the fly only where the
/// specification needs to classify them.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>

namespace fulltext::utf8 {

/// A decoded code point and the number of bytes it occupies.
struct Decoded {
  char32_t cp;
  unsigned len;
};

/// Decodes the code point starting at byte `i` of `s` (`i < s.size()`).
/// A malformed byte decodes as U+FFFD with length 1, so scanning always
/// makes progress.
Decoded decode(std::string_view s, std::size_t i) noexcept;

/// Appends `cp` to `out` encoded as UTF-8.
void append(std::string& out, char32_t cp);

/// If a whitespace code point starts at byte `i`, returns its length in bytes,
/// otherwise 0. Whitespace is exactly U+0009..U+000D, U+0020 and U+00A0.
unsigned whitespace_length_at(std::string_view s, std::size_t i) noexcept;

/// Removes leading and trailing whitespace (as defined above).
std::string_view strip(std::string_view s) noexcept;

}  // namespace fulltext::utf8
