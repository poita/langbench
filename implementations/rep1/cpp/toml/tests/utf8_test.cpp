#include <gtest/gtest.h>

#include "toml/utf8.hpp"

using toml::append_utf8;
using toml::is_valid_utf8;

TEST(Utf8, AcceptsAsciiAndMultibyte) {
  EXPECT_TRUE(is_valid_utf8(""));
  EXPECT_TRUE(is_valid_utf8("hello"));
  EXPECT_TRUE(is_valid_utf8("\xC3\xA9"));              // U+00E9
  EXPECT_TRUE(is_valid_utf8("\xE2\x82\xAC"));          // U+20AC
  EXPECT_TRUE(is_valid_utf8("\xF0\x9F\x98\x80"));      // U+1F600
  EXPECT_TRUE(is_valid_utf8("\xF4\x8F\xBF\xBF"));      // U+10FFFF
}

TEST(Utf8, RejectsMalformedSequences) {
  EXPECT_FALSE(is_valid_utf8("\xFF"));
  EXPECT_FALSE(is_valid_utf8("\xC3"));                 // truncated
  EXPECT_FALSE(is_valid_utf8("\xC0\x80"));             // overlong
  EXPECT_FALSE(is_valid_utf8("\xE0\x80\x80"));         // overlong
  EXPECT_FALSE(is_valid_utf8("\xED\xA0\x80"));         // surrogate
  EXPECT_FALSE(is_valid_utf8("\xF4\x90\x80\x80"));     // > U+10FFFF
  EXPECT_FALSE(is_valid_utf8("\x80"));                 // stray continuation
  EXPECT_FALSE(is_valid_utf8("\xC3\x28"));             // bad continuation
}

TEST(Utf8, AppendEncodesEveryLength) {
  std::string s;
  append_utf8(s, 0x41);
  append_utf8(s, 0xE9);
  append_utf8(s, 0x20AC);
  append_utf8(s, 0x1F600);
  EXPECT_EQ(s, "A\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80");
  EXPECT_TRUE(is_valid_utf8(s));
}
