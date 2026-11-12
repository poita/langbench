#include "protowire/utf8.hpp"

#include <cstddef>
#include <cstdint>

namespace protowire {

bool isValidUtf8(std::string_view s) {
  const std::size_t n = s.size();
  auto at = [&](std::size_t i) { return static_cast<std::uint8_t>(s[i]); };
  auto cont = [&](std::size_t i, std::uint8_t lo = 0x80, std::uint8_t hi = 0xbf) {
    return i < n && at(i) >= lo && at(i) <= hi;
  };
  std::size_t i = 0;
  while (i < n) {
    const std::uint8_t b = at(i);
    if (b < 0x80) { ++i; continue; }
    if (b >= 0xc2 && b <= 0xdf) {
      if (!cont(i + 1)) return false;
      i += 2;
    } else if (b >= 0xe0 && b <= 0xef) {
      std::uint8_t lo = 0x80, hi = 0xbf;
      if (b == 0xe0) lo = 0xa0;       // no overlong
      else if (b == 0xed) hi = 0x9f;  // no surrogates
      if (!cont(i + 1, lo, hi) || !cont(i + 2)) return false;
      i += 3;
    } else if (b >= 0xf0 && b <= 0xf4) {
      std::uint8_t lo = 0x80, hi = 0xbf;
      if (b == 0xf0) lo = 0x90;       // no overlong
      else if (b == 0xf4) hi = 0x8f;  // <= U+10FFFF
      if (!cont(i + 1, lo, hi) || !cont(i + 2) || !cont(i + 3)) return false;
      i += 4;
    } else {
      return false;
    }
  }
  return true;
}

}  // namespace protowire
