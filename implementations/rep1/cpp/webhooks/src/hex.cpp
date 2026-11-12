#include "webhooks/hex.hpp"

namespace webhooks {

std::string to_hex(ByteView bytes) {
  static constexpr char kDigits[] = "0123456789abcdef";
  std::string out;
  out.reserve(bytes.size() * 2);
  for (std::uint8_t b : bytes) {
    out.push_back(kDigits[b >> 4]);
    out.push_back(kDigits[b & 0x0f]);
  }
  return out;
}

namespace {
int nibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}
}  // namespace

std::optional<Bytes> from_hex(std::string_view hex) {
  if (hex.size() % 2 != 0) return std::nullopt;
  Bytes out;
  out.reserve(hex.size() / 2);
  for (std::size_t i = 0; i < hex.size(); i += 2) {
    int hi = nibble(hex[i]);
    int lo = nibble(hex[i + 1]);
    if (hi < 0 || lo < 0) return std::nullopt;
    out.push_back(static_cast<std::uint8_t>(hi << 4 | lo));
  }
  return out;
}

}  // namespace webhooks
