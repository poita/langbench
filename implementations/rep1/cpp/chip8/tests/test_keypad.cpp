#include <gtest/gtest.h>

#include "chip8/keypad.hpp"

using namespace chip8;

TEST(Keypad, DownAndLowest) {
  Keypad k(0x0300);
  EXPECT_TRUE(k.is_down(8));
  EXPECT_TRUE(k.is_down(9));
  EXPECT_FALSE(k.is_down(7));
  EXPECT_EQ(k.lowest_down(), 8);
  EXPECT_EQ(Keypad().lowest_down(), -1);
}

TEST(Keypad, KeyIndexIsMaskedToLowNibble) {
  Keypad k(0x0001);
  EXPECT_TRUE(k.is_down(0x10));
  EXPECT_TRUE(k.is_down(0xF0));
}

TEST(KeySchedule, ConsumesEventsInOrder) {
  KeySchedule s({{2, 0x1}, {5, 0x2}});
  EXPECT_EQ(s.next_cycle(), 2u);
  EXPECT_EQ(s.take_due(0), nullptr);
  EXPECT_EQ(s.take_due(1), nullptr);
  const KeyEvent* e = s.take_due(2);
  ASSERT_NE(e, nullptr);
  EXPECT_EQ(e->mask, 0x1);
  EXPECT_EQ(s.take_due(2), nullptr);
  EXPECT_EQ(s.next_cycle(), 5u);
  ASSERT_NE(s.take_due(5), nullptr);
  EXPECT_EQ(s.next_cycle(), UINT64_MAX);
  s.rewind();
  EXPECT_EQ(s.next_cycle(), 2u);
}
