#include <gtest/gtest.h>

#include "minisql/like.hpp"

using minisql::like_match;

TEST(Like, Wildcards) {
  EXPECT_TRUE(like_match("apple", "a%"));
  EXPECT_TRUE(like_match("apple", "%le"));
  EXPECT_TRUE(like_match("apple", "a_p_e"));
  EXPECT_TRUE(like_match("", "%"));
  EXPECT_FALSE(like_match("", "_"));
  EXPECT_FALSE(like_match("apple", "a_e"));
  EXPECT_TRUE(like_match("abcabc", "%abc"));
  EXPECT_TRUE(like_match("aXbXc", "%X%X%"));
  EXPECT_FALSE(like_match("aXb", "%X%X%"));
}

TEST(Like, WholeStringMustMatch) {
  EXPECT_FALSE(like_match("apple", "app"));
  EXPECT_FALSE(like_match("apple", "ppl"));
}

TEST(Like, AsciiCaseInsensitiveOnly) {
  EXPECT_TRUE(like_match("APPLE", "apple"));
  EXPECT_TRUE(like_match("Ab_c", "ab%"));
  EXPECT_FALSE(like_match("\xC3\x89", "\xC3\xA9"));
}

TEST(Like, UnderscoreMatchesOneCodePoint) {
  EXPECT_TRUE(like_match("\xC3\xA9", "_"));
  EXPECT_TRUE(like_match("a\xE2\x82\xAC" "b", "a_b"));
  EXPECT_FALSE(like_match("\xC3\xA9", "__"));
}

TEST(Like, PathologicalPatternIsFast) {
  std::string s(5000, 'a');
  EXPECT_FALSE(like_match(s, "%a%a%a%a%a%a%a%b"));
}
