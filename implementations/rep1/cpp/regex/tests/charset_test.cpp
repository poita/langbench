#include <gtest/gtest.h>

#include "regex/charset.hpp"

using regex::CharSet;

TEST(CharSet, StartsEmpty) {
  CharSet s;
  EXPECT_TRUE(s.empty());
  for (int c = 0; c < 256; ++c) EXPECT_FALSE(s.contains(static_cast<unsigned char>(c)));
}

TEST(CharSet, AddAndRange) {
  CharSet s;
  s.add('x');
  s.add_range('0', '9');
  EXPECT_TRUE(s.contains('x'));
  EXPECT_TRUE(s.contains('0'));
  EXPECT_TRUE(s.contains('9'));
  EXPECT_FALSE(s.contains('a'));
  EXPECT_FALSE(s.empty());
}

TEST(CharSet, RangeToTopOfByteRange) {
  CharSet s;
  s.add_range(250, 255);
  EXPECT_TRUE(s.contains(255));
  EXPECT_FALSE(s.contains(249));
}

TEST(CharSet, InvertCoversAllBytes) {
  CharSet s = CharSet::digits();
  s.invert();
  EXPECT_FALSE(s.contains('5'));
  EXPECT_TRUE(s.contains('a'));
  EXPECT_TRUE(s.contains(200));
}

TEST(CharSet, InvertAsciiLeavesHighBytesOut) {
  CharSet s = CharSet::word();
  s.invert_ascii();
  EXPECT_TRUE(s.contains('-'));
  EXPECT_FALSE(s.contains('_'));
  EXPECT_FALSE(s.contains(200));
}

TEST(CharSet, NamedSets) {
  EXPECT_TRUE(CharSet::space().contains(' '));
  EXPECT_TRUE(CharSet::space().contains('\v'));
  EXPECT_FALSE(CharSet::space().contains('x'));
  EXPECT_TRUE(CharSet::word().contains('_'));
  EXPECT_FALSE(CharSet::word().contains('-'));
  EXPECT_EQ(CharSet::single('a'), CharSet::single('a'));
  EXPECT_FALSE(CharSet::single('a') == CharSet::single('b'));
}

TEST(CharSet, AddAll) {
  CharSet a = CharSet::digits();
  a.add_all(CharSet::single('z'));
  EXPECT_TRUE(a.contains('z'));
  EXPECT_TRUE(a.contains('3'));
}
