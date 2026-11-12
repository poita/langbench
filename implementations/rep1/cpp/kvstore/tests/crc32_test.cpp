#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "tessera/crc32.hpp"

using tessera::crc32;

static std::uint32_t of(const std::string& s) {
  return crc32(reinterpret_cast<const std::uint8_t*>(s.data()), s.size());
}

TEST(Crc32, SpecVectors) {
  EXPECT_EQ(of(""), 0x00000000u);
  EXPECT_EQ(of("a"), 0xE8B7BE43u);
  EXPECT_EQ(of("123456789"), 0xCBF43926u);
  EXPECT_EQ(of("TESSERA1"), 0x2C9A9B66u);
  EXPECT_EQ(of("TESSWAL1"), 0x7D446716u);
  EXPECT_EQ(of(std::string(20, '\0')), 0x0FD59B8Du);
  EXPECT_EQ(of(std::string(1024, '\0')), 0xEFB5AF2Eu);
}

TEST(Crc32, IncrementalMatchesOneShot) {
  std::string s = "hello, tessera";
  auto* p = reinterpret_cast<const std::uint8_t*>(s.data());
  auto state = tessera::crc32_init();
  state = tessera::crc32_update(state, p, 5);
  state = tessera::crc32_update(state, p + 5, s.size() - 5);
  EXPECT_EQ(tessera::crc32_final(state), of(s));
}
