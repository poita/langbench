#include "minisql/like.hpp"

#include <cstddef>

namespace minisql {

namespace {

unsigned char fold(unsigned char c) {
  return (c >= 'A' && c <= 'Z') ? static_cast<unsigned char>(c + 32) : c;
}

// Length in bytes of the UTF-8 character starting at s[i], clamped to the end.
std::size_t char_length(std::string_view s, std::size_t i) {
  const unsigned char c = static_cast<unsigned char>(s[i]);
  std::size_t n = 1;
  if (c >= 0xF0) n = 4;
  else if (c >= 0xE0) n = 3;
  else if (c >= 0xC0) n = 2;
  return i + n > s.size() ? s.size() - i : n;
}

}  // namespace

bool like_match(std::string_view s, std::string_view p) {
  constexpr std::size_t npos = static_cast<std::size_t>(-1);
  std::size_t si = 0, pi = 0;
  std::size_t star_p = npos, star_s = 0;
  while (si < s.size()) {
    if (pi < p.size() && p[pi] == '%') {
      star_p = pi++;
      star_s = si;
    } else if (pi < p.size() && p[pi] == '_') {
      si += char_length(s, si);
      ++pi;
    } else if (pi < p.size() &&
               fold(static_cast<unsigned char>(p[pi])) ==
                   fold(static_cast<unsigned char>(s[si]))) {
      ++si;
      ++pi;
    } else if (star_p != npos) {
      // Backtrack: let the last '%' swallow one more character.
      star_s += char_length(s, star_s);
      si = star_s;
      pi = star_p + 1;
    } else {
      return false;
    }
  }
  while (pi < p.size() && p[pi] == '%') ++pi;
  return pi == p.size();
}

}  // namespace minisql
