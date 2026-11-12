#include <gtest/gtest.h>

#include "fulltext/utf8.hpp"

using namespace fulltext;

TEST(Utf8, DecodesAllLengths) {
  const std::string s = "a\xC3\xA9\xE2\x80\x99\xF0\x9F\x98\x80";  // a é ’ 😀
  auto d = utf8::decode(s, 0);
  EXPECT_EQ(d.cp, U'a');
  EXPECT_EQ(d.len, 1u);
  d = utf8::decode(s, 1);
  EXPECT_EQ(d.cp, U'é');
  EXPECT_EQ(d.len, 2u);
  d = utf8::decode(s, 3);
  EXPECT_EQ(d.cp, U'’');
  EXPECT_EQ(d.len, 3u);
  d = utf8::decode(s, 6);
  EXPECT_EQ(d.cp, U'\U0001F600');
  EXPECT_EQ(d.len, 4u);
}

TEST(Utf8, MalformedByteMakesProgress) {
  const std::string s = "\xFF";
  EXPECT_EQ(utf8::decode(s, 0).len, 1u);
}

TEST(Utf8, AppendRoundTrips) {
  std::string s;
  for (char32_t c : {U'a', U'é', U'’', U'\U0001F600'}) utf8::append(s, c);
  EXPECT_EQ(s, "a\xC3\xA9\xE2\x80\x99\xF0\x9F\x98\x80");
}

TEST(Utf8, WhitespaceIncludesNbspButNotOtherSpaces) {
  EXPECT_EQ(utf8::whitespace_length_at(" ", 0), 1u);
  EXPECT_EQ(utf8::whitespace_length_at("\t", 0), 1u);
  EXPECT_EQ(utf8::whitespace_length_at("\v", 0), 1u);
  EXPECT_EQ(utf8::whitespace_length_at("\xC2\xA0", 0), 2u);
  EXPECT_EQ(utf8::whitespace_length_at("\xE2\x80\x83", 0), 0u);  // em space
  EXPECT_EQ(utf8::whitespace_length_at("x", 0), 0u);
}

TEST(Utf8, StripTrimsBothEnds) {
  EXPECT_EQ(utf8::strip("\xC2\xA0 \t foo bar\xC2\xA0\r"), "foo bar");
  EXPECT_EQ(utf8::strip("   "), "");
  EXPECT_EQ(utf8::strip(""), "");
  EXPECT_EQ(utf8::strip("\xC2\xA0"), "");
  EXPECT_EQ(utf8::strip("\xC3\xA0"), "\xC3\xA0");  // à ends in 0xA0 but is not NBSP
}
