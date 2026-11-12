#include <gtest/gtest.h>

#include "inflate/hex.hpp"

using namespace inflate;

TEST(Hex, DecodeBasic) {
  std::vector<std::uint8_t> out;
  ASSERT_TRUE(hex_decode("00ff10Ab", out));
  EXPECT_EQ(out, (std::vector<std::uint8_t>{0x00, 0xFF, 0x10, 0xAB}));
}

TEST(Hex, DecodeEmptyAndWhitespace) {
  std::vector<std::uint8_t> out{1};
  EXPECT_TRUE(hex_decode("", out));
  EXPECT_TRUE(out.empty());
  EXPECT_TRUE(hex_decode("\n", out));
  EXPECT_TRUE(out.empty());
  ASSERT_TRUE(hex_decode("  0a0b\r\n", out));
  EXPECT_EQ(out.size(), 2u);
}

TEST(Hex, RejectsMalformed) {
  std::vector<std::uint8_t> out;
  EXPECT_FALSE(hex_decode("abc", out));
  EXPECT_FALSE(hex_decode("zz", out));
  EXPECT_FALSE(hex_decode("0g", out));
  EXPECT_FALSE(hex_decode("ab cd", out));
  EXPECT_TRUE(out.empty());
}

TEST(Hex, EncodeLowercase) {
  const std::vector<std::uint8_t> in{0x00, 0xAB, 0xFF, 0x07};
  EXPECT_EQ(hex_encode(in), "00abff07");
  EXPECT_EQ(hex_encode(std::vector<std::uint8_t>{}), "");
}

TEST(Hex, RoundTripAllBytes) {
  std::vector<std::uint8_t> in(256);
  for (int i = 0; i < 256; ++i) in[i] = static_cast<std::uint8_t>(i);
  std::vector<std::uint8_t> out;
  ASSERT_TRUE(hex_decode(hex_encode(in), out));
  EXPECT_EQ(in, out);
}
