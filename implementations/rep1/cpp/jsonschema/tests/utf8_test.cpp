#include <gtest/gtest.h>

#include "jsonschema/utf8.hpp"

using namespace jsonschema;

TEST(Utf8, LengthCountsCodePoints) {
  EXPECT_EQ(utf8::length(""), 0u);
  EXPECT_EQ(utf8::length("abc"), 3u);
  EXPECT_EQ(utf8::length("\xC3\xA9"), 1u);              // é
  EXPECT_EQ(utf8::length("e\xCC\x81"), 2u);             // e + combining acute
  EXPECT_EQ(utf8::length("\xF0\x9F\x92\xA9"), 1u);      // U+1F4A9
}

TEST(Utf8, DecodeAndAppendRoundTrip) {
  for (char32_t cp : {U'a', char32_t{0xE9}, char32_t{0x20AC}, char32_t{0x1F4A9}, char32_t{0x10FFFF}}) {
    std::string s;
    utf8::append(s, cp);
    std::u32string d = utf8::decode(s);
    ASSERT_EQ(d.size(), 1u);
    EXPECT_EQ(d[0], cp);
  }
}

TEST(Utf8, MalformedBytesBecomeReplacement) {
  std::u32string d = utf8::decode("a\xFF" "b\xE2\x82");
  ASSERT_EQ(d.size(), 5u);  // a, bad, b, then the truncated sequence: one per byte
  EXPECT_EQ(d[1], char32_t{0xFFFD});
}
