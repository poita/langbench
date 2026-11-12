#include "kiln/hash.hpp"

namespace kiln {

std::uint64_t fnv1a64(std::string_view bytes) noexcept {
  std::uint64_t h = 0xcbf29ce484222325ULL;
  for (unsigned char b : bytes) {
    h ^= b;
    h *= 0x100000001b3ULL;
  }
  return h;
}

std::string hash_to_hex(std::uint64_t hash) {
  static const char digits[] = "0123456789abcdef";
  std::string s(16, '0');
  for (int i = 15; i >= 0; --i) {
    s[static_cast<std::size_t>(i)] = digits[hash & 0xf];
    hash >>= 4;
  }
  return s;
}

bool hash_from_hex(std::string_view text, std::uint64_t& out) noexcept {
  if (text.size() != 16) return false;
  std::uint64_t v = 0;
  for (char c : text) {
    unsigned d;
    if (c >= '0' && c <= '9') d = static_cast<unsigned>(c - '0');
    else if (c >= 'a' && c <= 'f') d = static_cast<unsigned>(c - 'a' + 10);
    else return false;
    v = (v << 4) | d;
  }
  out = v;
  return true;
}

}  // namespace kiln
