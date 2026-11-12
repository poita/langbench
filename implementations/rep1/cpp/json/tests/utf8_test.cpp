#include <gtest/gtest.h>

#include <string>

#include "jsoncanon/utf8.hpp"

using namespace jsoncanon;

TEST(Utf8Valid, AcceptsAsciiAndMultibyte) {
  EXPECT_TRUE(utf8::is_valid(""));
  EXPECT_TRUE(utf8::is_valid("hello"));
  EXPECT_TRUE(utf8::is_valid(std::string_view("a\0b", 3)));
  EXPECT_TRUE(utf8::is_valid("\xC3\xA9"));              // U+00E9
  EXPECT_TRUE(utf8::is_valid("\xE2\x82\xAC"));          // U+20AC
  EXPECT_TRUE(utf8::is_valid("\xF0\x9F\x98\x80"));      // U+1F600
  EXPECT_TRUE(utf8::is_valid("\xED\x9F\xBF"));          // U+D7FF
  EXPECT_TRUE(utf8::is_valid("\xEE\x80\x80"));          // U+E000
  EXPECT_TRUE(utf8::is_valid("\xF4\x8F\xBF\xBF"));      // U+10FFFF
}

TEST(Utf8Valid, RejectsMalformed) {
  EXPECT_FALSE(utf8::is_valid("\x80"));                  // stray continuation
  EXPECT_FALSE(utf8::is_valid("\xC0\x80"));              // overlong NUL
  EXPECT_FALSE(utf8::is_valid("\xC1\xBF"));              // overlong
  EXPECT_FALSE(utf8::is_valid("\xE0\x80\x80"));          // overlong 3-byte
  EXPECT_FALSE(utf8::is_valid("\xF0\x80\x80\x80"));      // overlong 4-byte
  EXPECT_FALSE(utf8::is_valid("\xED\xA0\x80"));          // U+D800
  EXPECT_FALSE(utf8::is_valid("\xED\xBF\xBF"));          // U+DFFF
  EXPECT_FALSE(utf8::is_valid("\xF4\x90\x80\x80"));      // U+110000
  EXPECT_FALSE(utf8::is_valid("\xF5\x80\x80\x80"));
  EXPECT_FALSE(utf8::is_valid("\xFF"));
  EXPECT_FALSE(utf8::is_valid("\xC3"));                  // truncated
  EXPECT_FALSE(utf8::is_valid("\xE2\x82"));
  EXPECT_FALSE(utf8::is_valid("\xF0\x9F\x98"));
  EXPECT_FALSE(utf8::is_valid("a\xC3("));                // bad continuation
}

TEST(Utf8Encode, AllLengths) {
  std::string s;
  utf8::append_code_point(s, 0x41);
  utf8::append_code_point(s, 0xE9);
  utf8::append_code_point(s, 0x20AC);
  utf8::append_code_point(s, 0x1F600);
  EXPECT_EQ(s, "A\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80");
  EXPECT_TRUE(utf8::is_valid(s));
}

TEST(Utf8Compare, Basic) {
  EXPECT_EQ(utf8::compare_utf16("a", "a"), 0);
  EXPECT_LT(utf8::compare_utf16("", "a"), 0);
  EXPECT_GT(utf8::compare_utf16("ab", "a"), 0);
  EXPECT_LT(utf8::compare_utf16("a", std::string_view("a\0", 2)), 0);
  EXPECT_LT(utf8::compare_utf16("Z", "a"), 0);
  EXPECT_LT(utf8::compare_utf16("aa", "\xC3\xA9"), 0);
}

TEST(Utf8Compare, SupplementarySortsBeforeUpperBmp) {
  const std::string emoji = "\xF0\x9F\x98\x80";  // U+1F600
  const std::string e000 = "\xEE\x80\x80";
  const std::string ffff = "\xEF\xBF\xBF";
  EXPECT_LT(utf8::compare_utf16(emoji, e000), 0);
  EXPECT_GT(utf8::compare_utf16(e000, emoji), 0);
  EXPECT_LT(utf8::compare_utf16(emoji, ffff), 0);
  EXPECT_LT(utf8::compare_utf16("\xC3\xA9", emoji), 0);
  EXPECT_LT(utf8::compare_utf16("\xED\x9F\xBF", emoji), 0);  // U+D7FF < U+1F600
  EXPECT_LT(utf8::compare_utf16("\xF0\x9F\x98\x80", "\xF0\x9F\x98\x81"), 0);
}

TEST(Utf8Compare, MaxCodePointSortsBeforeUpperBmp) {
  EXPECT_LT(utf8::compare_utf16("\xF4\x8F\xBF\xBF", "\xEE\x80\x80"), 0);  // U+10FFFF < U+E000
  EXPECT_LT(utf8::compare_utf16("\xF4\x8F\xBF\xBF", "\xEF\xBF\xBF"), 0);
}
