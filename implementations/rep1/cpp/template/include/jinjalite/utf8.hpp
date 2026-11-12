#pragma once
/// \file utf8.hpp
/// Minimal UTF-8 helpers. Strings are stored as UTF-8 bytes; the template
/// language is defined over Unicode code points.

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace jinjalite {

/// Number of bytes of the sequence introduced by lead byte `lead` (1 for a
/// stray continuation byte).
inline size_t utf8_sequence_size(unsigned char lead) noexcept {
  if (lead < 0xC0) return 1;
  if (lead < 0xE0) return 2;
  if (lead < 0xF0) return 3;
  return 4;
}

/// Number of code points in `s`.
inline size_t utf8_length(std::string_view s) noexcept {
  size_t n = 0;
  for (unsigned char c : s) n += (c & 0xC0) != 0x80;
  return n;
}

/// Splits `s` into one view per code point.
inline std::vector<std::string_view> utf8_split(std::string_view s) {
  std::vector<std::string_view> out;
  out.reserve(s.size());
  size_t i = 0;
  while (i < s.size()) {
    size_t n = utf8_sequence_size(static_cast<unsigned char>(s[i]));
    if (i + n > s.size()) n = s.size() - i;
    out.push_back(s.substr(i, n));
    i += n;
  }
  return out;
}

/// Appends code point `cp` to `out` encoded as UTF-8.
inline void utf8_append(std::string& out, uint32_t cp) {
  if (cp < 0x80) {
    out += static_cast<char>(cp);
  } else if (cp < 0x800) {
    out += static_cast<char>(0xC0 | (cp >> 6));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  } else if (cp < 0x10000) {
    out += static_cast<char>(0xE0 | (cp >> 12));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  } else {
    out += static_cast<char>(0xF0 | (cp >> 18));
    out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  }
}

}  // namespace jinjalite
