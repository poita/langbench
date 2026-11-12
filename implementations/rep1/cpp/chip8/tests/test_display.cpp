#include <gtest/gtest.h>

#include <array>

#include "chip8/display.hpp"

using chip8::Display;

namespace {
bool draw(Display& d, int x, int y, std::initializer_list<unsigned> rows) {
  std::vector<unsigned> v(rows);
  return d.draw_sprite(x, y, static_cast<int>(v.size()), [&](int i) { return v[i]; });
}
}  // namespace

TEST(Display, StartsBlank) {
  Display d;
  for (int y = 0; y < Display::kHeight; ++y)
    for (int x = 0; x < Display::kWidth; ++x) ASSERT_FALSE(d.pixel(x, y));
}

TEST(Display, ToggleReportsPreviousState) {
  Display d;
  EXPECT_FALSE(d.toggle(3, 4));
  EXPECT_TRUE(d.pixel(3, 4));
  EXPECT_TRUE(d.toggle(3, 4));
  EXPECT_FALSE(d.pixel(3, 4));
}

TEST(Display, SpriteBitOrderIsMsbLeft) {
  Display d;
  EXPECT_FALSE(draw(d, 10, 5, {0x81}));
  EXPECT_TRUE(d.pixel(10, 5));
  EXPECT_TRUE(d.pixel(17, 5));
  EXPECT_FALSE(d.pixel(11, 5));
}

TEST(Display, DrawingTwiceCollidesAndErases) {
  Display d;
  draw(d, 0, 0, {0xFF});
  EXPECT_TRUE(draw(d, 0, 0, {0xFF}));
  EXPECT_EQ(d, Display());
}

TEST(Display, WrapsRightAndBottom) {
  Display d;
  draw(d, 62, 31, {0xF0, 0x90});
  EXPECT_TRUE(d.pixel(62, 31));
  EXPECT_TRUE(d.pixel(63, 31));
  EXPECT_TRUE(d.pixel(0, 31));
  EXPECT_TRUE(d.pixel(1, 31));
  EXPECT_TRUE(d.pixel(62, 0));
  EXPECT_TRUE(d.pixel(1, 0));
  EXPECT_FALSE(d.pixel(63, 0));
}

TEST(Display, OriginIsReducedModuloSize) {
  Display d;
  draw(d, 64 + 5, 32 + 6, {0x80});
  EXPECT_TRUE(d.pixel(5, 6));
}

TEST(Display, ZeroRowsDrawsNothing) {
  Display d;
  EXPECT_FALSE(draw(d, 0, 0, {}));
  EXPECT_EQ(d, Display());
}

TEST(Display, ToTextShape) {
  Display d;
  d.toggle(0, 0);
  d.toggle(63, 31);
  const std::string t = d.to_text();
  EXPECT_EQ(t.size(), 32u * 65u);
  EXPECT_EQ(t.substr(0, 3), "#..");
  EXPECT_EQ(t.substr(t.size() - 3), ".#\n");
}

TEST(Display, ClearTurnsEverythingOff) {
  Display d;
  d.toggle(7, 7);
  d.clear();
  EXPECT_EQ(d, Display());
}
