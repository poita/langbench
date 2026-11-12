#include "protowire/hex.hpp"

#include "protowire/error.hpp"

namespace protowire {

void appendHex(std::string& out, std::span<const std::uint8_t> bytes) {
  static constexpr char kDigits[] = "0123456789abcdef";
  const std::size_t base = out.size();
  out.resize(base + bytes.size() * 2);
  char* p = out.data() + base;
  for (std::uint8_t b : bytes) {
    *p++ = kDigits[b >> 4];
    *p++ = kDigits[b & 15];
  }
}

std::string toHex(std::span<const std::uint8_t> bytes) {
  std::string s;
  appendHex(s, bytes);
  return s;
}

namespace {
int hexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}
}  // namespace

std::vector<std::uint8_t> fromHex(std::string_view hex) {
  if (hex.size() % 2 != 0) throw HexError("odd number of hex digits");
  std::vector<std::uint8_t> out(hex.size() / 2);
  for (std::size_t i = 0; i < out.size(); ++i) {
    const int hi = hexValue(hex[2 * i]), lo = hexValue(hex[2 * i + 1]);
    if (hi < 0 || lo < 0) throw HexError("invalid hex digit");
    out[i] = static_cast<std::uint8_t>(hi << 4 | lo);
  }
  return out;
}

}  // namespace protowire
