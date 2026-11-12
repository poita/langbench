#include <gtest/gtest.h>

#include "sitegen/text.hpp"

using namespace sitegen::text;

TEST(Text, AppendUtf8EncodesEveryLength) {
  std::string s;
  append_utf8(s, U'A');
  append_utf8(s, U'\u00e9');
  append_utf8(s, U'\u20ac');
  append_utf8(s, U'\U0001F600');
  EXPECT_EQ(s, "A\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80");
}

TEST(Text, Utf8LengthCountsCodePoints) {
  EXPECT_EQ(utf8_length(""), 0u);
  EXPECT_EQ(utf8_length("abc"), 3u);
  EXPECT_EQ(utf8_length("h\xC3\xA9llo \xE2\x82\xAC \xF0\x9F\x98\x80"), 9u);
}

TEST(Text, SequenceLengthFromLeadByte) {
  EXPECT_EQ(utf8_sequence_length('a'), 1u);
  EXPECT_EQ(utf8_sequence_length(0xC3), 2u);
  EXPECT_EQ(utf8_sequence_length(0xE2), 3u);
  EXPECT_EQ(utf8_sequence_length(0xF0), 4u);
}

TEST(Text, AsciiCaseMappingLeavesOtherBytesAlone) {
  EXPECT_EQ(ascii_lower("Hello \xC3\x89 WORLD 1"), "hello \xC3\x89 world 1");
  EXPECT_EQ(ascii_upper("Hello \xC3\xA9 world 1"), "HELLO \xC3\xA9 WORLD 1");
}

TEST(Text, TemplateSpaceIsTheSixCharacters) {
  for (const char c : {' ', '\t', '\n', '\r', '\f', '\v'}) EXPECT_TRUE(is_template_space(c));
  EXPECT_FALSE(is_template_space('a'));
  EXPECT_FALSE(is_template_space('\0'));
}
