#include "jsoncanon/utf8.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace jsoncanon::utf8 {

namespace {
inline bool cont(unsigned char c) { return (c & 0xC0) == 0x80; }
}  // namespace

bool is_valid(std::string_view s) noexcept {
  const auto* p = reinterpret_cast<const unsigned char*>(s.data());
  const std::size_t n = s.size();
  std::size_t i = 0;
  while (i < n) {
    const unsigned char c = p[i];
    if (c < 0x80) {
      ++i;
      continue;
    }
    if (c < 0xC2) return false;  // continuation byte or overlong 2-byte lead
    if (c < 0xE0) {
      if (i + 1 >= n || !cont(p[i + 1])) return false;
      i += 2;
    } else if (c < 0xF0) {
      if (i + 2 >= n) return false;
      const unsigned char c1 = p[i + 1];
      if (!cont(c1) || !cont(p[i + 2])) return false;
      if (c == 0xE0 && c1 < 0xA0) return false;  // overlong
      if (c == 0xED && c1 >= 0xA0) return false;  // surrogates
      i += 3;
    } else if (c < 0xF5) {
      if (i + 3 >= n) return false;
      const unsigned char c1 = p[i + 1];
      if (!cont(c1) || !cont(p[i + 2]) || !cont(p[i + 3])) return false;
      if (c == 0xF0 && c1 < 0x90) return false;  // overlong
      if (c == 0xF4 && c1 >= 0x90) return false;  // > U+10FFFF
      i += 4;
    } else {
      return false;
    }
  }
  return true;
}

void append_code_point(std::string& out, char32_t cp) {
  if (cp < 0x80) {
    out.push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

namespace {

// Decodes the code point starting at s[i]; tolerant of malformed input (never
// reads out of range, returns the lead byte on error).
char32_t decode_at(std::string_view s, std::size_t i) noexcept {
  const auto b = [&](std::size_t k) { return static_cast<unsigned char>(s[k]); };
  const unsigned char c = b(i);
  const std::size_t rem = s.size() - i;
  if (c < 0x80) return c;
  if (c >= 0xC2 && c < 0xE0 && rem >= 2) return ((c & 0x1Fu) << 6) | (b(i + 1) & 0x3Fu);
  if (c >= 0xE0 && c < 0xF0 && rem >= 3)
    return ((c & 0x0Fu) << 12) | ((b(i + 1) & 0x3Fu) << 6) | (b(i + 2) & 0x3Fu);
  if (c >= 0xF0 && c < 0xF5 && rem >= 4)
    return ((c & 0x07u) << 18) | ((b(i + 1) & 0x3Fu) << 12) | ((b(i + 2) & 0x3Fu) << 6) |
           (b(i + 3) & 0x3Fu);
  return c;
}

// Order of a code point under UTF-16 code unit ordering: the BMP above the
// surrogate block (U+E000..U+FFFF) sorts after every supplementary character.
inline std::uint32_t utf16_rank(char32_t cp) noexcept {
  return (cp >= 0xE000 && cp <= 0xFFFF) ? cp + 0x200000u : cp;
}

}  // namespace

int compare_utf16(std::string_view a, std::string_view b) noexcept {
  const std::size_t n = std::min(a.size(), b.size());
  std::size_t i = 0;
  while (i < n && a[i] == b[i]) ++i;
  if (i == n) return a.size() < b.size() ? -1 : (a.size() > b.size() ? 1 : 0);
  // Back up to the start of the (shared) character containing the mismatch.
  std::size_t s = i;
  while (s > 0 && cont(static_cast<unsigned char>(a[s]))) --s;
  const std::uint32_t ra = utf16_rank(decode_at(a, s));
  const std::uint32_t rb = utf16_rank(decode_at(b, s));
  if (ra != rb) return ra < rb ? -1 : 1;
  // Only reachable for malformed input; fall back to byte order.
  return static_cast<unsigned char>(a[i]) < static_cast<unsigned char>(b[i]) ? -1 : 1;
}

}  // namespace jsoncanon::utf8
