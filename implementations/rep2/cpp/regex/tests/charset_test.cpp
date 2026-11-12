#include <gtest/gtest.h>

#include "rx/charset.hpp"

TEST(CharSet, AddAndContains) {
  rx::CharSet s;
  EXPECT_TRUE(s.empty());
  s.add('a');
  s.add_range('0', '3');
  EXPECT_TRUE(s.contains('a'));
  EXPECT_TRUE(s.contains('2'));
  EXPECT_FALSE(s.contains('4'));
  EXPECT_EQ(s.size(), 5u);
}

TEST(CharSet, Invert) {
  rx::CharSet s = rx::CharSet::digits();
  s.invert();
  EXPECT_FALSE(s.contains('5'));
  EXPECT_TRUE(s.contains('x'));
  EXPECT_EQ(s.size(), 246u);
}

TEST(CharSet, Presets) {
  EXPECT_EQ(rx::CharSet::digits().size(), 10u);
  EXPECT_EQ(rx::CharSet::word().size(), 63u);
  EXPECT_TRUE(rx::CharSet::word().contains('_'));
  EXPECT_TRUE(rx::CharSet::space().contains(' '));
  EXPECT_TRUE(rx::CharSet::space().contains('\t'));
  EXPECT_FALSE(rx::CharSet::space().contains('a'));
}
