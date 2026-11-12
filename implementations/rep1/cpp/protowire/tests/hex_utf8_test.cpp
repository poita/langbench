#include <gtest/gtest.h>

#include <vector>

#include "protowire/error.hpp"
#include "protowire/hex.hpp"
#include "protowire/utf8.hpp"

using namespace protowire;

TEST(Hex, RoundTrip) {
  std::vector<std::uint8_t> b{0x00, 0x0f, 0xab, 0xff};
  EXPECT_EQ(toHex(b), "000fabff");
  EXPECT_EQ(fromHex("000fabff"), b);
  EXPECT_TRUE(fromHex("").empty());
}

TEST(Hex, Rejects) {
  EXPECT_THROW(fromHex("abc"), HexError);
  EXPECT_THROW(fromHex("AB"), HexError);
  EXPECT_THROW(fromHex("0g"), HexError);
  EXPECT_THROW(fromHex("00 "), HexError);
}

TEST(Utf8, Valid) {
  EXPECT_TRUE(isValidUtf8(""));
  EXPECT_TRUE(isValidUtf8(std::string_view("a\0b", 3)));
  EXPECT_TRUE(isValidUtf8("\xc3\xa9"));          // é
  EXPECT_TRUE(isValidUtf8("\xe2\x82\xac"));      // €
  EXPECT_TRUE(isValidUtf8("\xf0\x9f\x98\x80"));  // U+1F600
  EXPECT_TRUE(isValidUtf8("\xf4\x8f\xbf\xbf"));  // U+10FFFF
  EXPECT_TRUE(isValidUtf8("\xed\x9f\xbf"));      // U+D7FF
}

TEST(Utf8, Invalid) {
  EXPECT_FALSE(isValidUtf8("\x80"));
  EXPECT_FALSE(isValidUtf8("\xc0\x80"));          // overlong
  EXPECT_FALSE(isValidUtf8("\xc1\xbf"));          // overlong
  EXPECT_FALSE(isValidUtf8("\xe0\x80\x80"));      // overlong
  EXPECT_FALSE(isValidUtf8("\xf0\x80\x80\x80"));  // overlong
  EXPECT_FALSE(isValidUtf8("\xed\xa0\x80"));      // surrogate U+D800
  EXPECT_FALSE(isValidUtf8("\xf4\x90\x80\x80"));  // > U+10FFFF
  EXPECT_FALSE(isValidUtf8("\xf5\x80\x80\x80"));
  EXPECT_FALSE(isValidUtf8("\xc3"));              // truncated
  EXPECT_FALSE(isValidUtf8("\xe2\x82"));
  EXPECT_FALSE(isValidUtf8("\xff"));
}
