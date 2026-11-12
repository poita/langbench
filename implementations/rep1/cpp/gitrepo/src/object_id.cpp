#include "gitrepo/object_id.hpp"

#include <algorithm>
#include <cstring>

namespace gitrepo {

namespace {
int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}
}  // namespace

std::optional<ObjectId> ObjectId::from_hex(std::string_view hex) {
  if (hex.size() != kHexSize) return std::nullopt;
  ObjectId id;
  for (std::size_t i = 0; i < kSize; ++i) {
    int hi = hex_value(hex[2 * i]);
    int lo = hex_value(hex[2 * i + 1]);
    if (hi < 0 || lo < 0) return std::nullopt;
    id.bytes[i] = static_cast<std::uint8_t>(hi * 16 + lo);
  }
  return id;
}

ObjectId ObjectId::from_raw(const char* raw20) {
  ObjectId id;
  std::memcpy(id.bytes.data(), raw20, kSize);
  return id;
}

std::string ObjectId::hex() const {
  static const char digits[] = "0123456789abcdef";
  std::string out(kHexSize, '0');
  for (std::size_t i = 0; i < kSize; ++i) {
    out[2 * i] = digits[bytes[i] >> 4];
    out[2 * i + 1] = digits[bytes[i] & 15];
  }
  return out;
}

bool ObjectId::is_null() const {
  return std::all_of(bytes.begin(), bytes.end(),
                     [](std::uint8_t b) { return b == 0; });
}

}  // namespace gitrepo
