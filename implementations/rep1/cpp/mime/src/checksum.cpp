#include "mime/checksum.hpp"

namespace mime {

std::uint32_t adler32(std::string_view data) {
  constexpr std::uint32_t kMod = 65521;
  std::uint32_t a = 1, b = 0;
  for (char c : data) {
    a = (a + static_cast<unsigned char>(c)) % kMod;
    b = (b + a) % kMod;
  }
  return b * 65536u + a;
}

std::string adler32_hex(std::string_view data) {
  static const char* hex = "0123456789abcdef";
  std::uint32_t v = adler32(data);
  std::string out(8, '0');
  for (int i = 7; i >= 0; --i) {
    out[i] = hex[v & 15];
    v >>= 4;
  }
  return out;
}

}  // namespace mime
