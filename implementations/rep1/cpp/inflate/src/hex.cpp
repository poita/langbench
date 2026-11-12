#include "inflate/hex.hpp"

#include <array>

namespace inflate {
namespace {

constexpr std::array<std::int8_t, 256> make_nibble_table() {
  std::array<std::int8_t, 256> t{};
  for (auto& v : t) v = -1;
  for (int i = 0; i < 10; ++i) t['0' + i] = static_cast<std::int8_t>(i);
  for (int i = 0; i < 6; ++i) {
    t['a' + i] = static_cast<std::int8_t>(10 + i);
    t['A' + i] = static_cast<std::int8_t>(10 + i);
  }
  return t;
}

constexpr auto kNibble = make_nibble_table();

bool is_space(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

}  // namespace

bool hex_decode(std::string_view text, std::vector<std::uint8_t>& out) {
  out.clear();
  while (!text.empty() && is_space(text.front())) text.remove_prefix(1);
  while (!text.empty() && is_space(text.back())) text.remove_suffix(1);
  if (text.size() % 2 != 0) return false;
  out.resize(text.size() / 2);
  for (std::size_t i = 0; i < out.size(); ++i) {
    int hi = kNibble[static_cast<unsigned char>(text[2 * i])];
    int lo = kNibble[static_cast<unsigned char>(text[2 * i + 1])];
    if ((hi | lo) < 0) {
      out.clear();
      return false;
    }
    out[i] = static_cast<std::uint8_t>(hi << 4 | lo);
  }
  return true;
}

std::string hex_encode(const std::uint8_t* data, std::size_t size) {
  static const char digits[] = "0123456789abcdef";
  std::string s(size * 2, '\0');
  for (std::size_t i = 0; i < size; ++i) {
    s[2 * i] = digits[data[i] >> 4];
    s[2 * i + 1] = digits[data[i] & 15];
  }
  return s;
}

std::string hex_encode(const std::vector<std::uint8_t>& data) {
  return hex_encode(data.data(), data.size());
}

}  // namespace inflate
