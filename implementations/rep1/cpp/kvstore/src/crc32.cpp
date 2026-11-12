#include "tessera/crc32.hpp"

#include <array>

namespace tessera {
namespace {

std::array<std::uint32_t, 256> make_table() {
  std::array<std::uint32_t, 256> table{};
  for (std::uint32_t i = 0; i < 256; ++i) {
    std::uint32_t c = i;
    for (int bit = 0; bit < 8; ++bit) c = (c & 1u) ? (c >> 1) ^ 0xEDB88320u : c >> 1;
    table[i] = c;
  }
  return table;
}

const std::array<std::uint32_t, 256>& table() {
  static const std::array<std::uint32_t, 256> t = make_table();
  return t;
}

}  // namespace

std::uint32_t crc32_update(std::uint32_t state, const std::uint8_t* data, std::size_t size) {
  const auto& t = table();
  for (std::size_t i = 0; i < size; ++i) state = t[(state ^ data[i]) & 0xFFu] ^ (state >> 8);
  return state;
}

std::uint32_t crc32(const std::uint8_t* data, std::size_t size) {
  return crc32_final(crc32_update(crc32_init(), data, size));
}

}  // namespace tessera
