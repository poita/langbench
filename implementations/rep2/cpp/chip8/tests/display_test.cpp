#include <gtest/gtest.h>

#include "chip8/display.hpp"

using chip8::Display;

TEST(Display, StartsBlank) {
    Display d;
    const std::string s = d.to_string();
    EXPECT_EQ(s.size(), 65u * 32u);
    EXPECT_EQ(s.find('#'), std::string::npos);
}

TEST(Display, ToggleReportsCollision) {
    Display d;
    EXPECT_FALSE(d.toggle(3, 4));
    EXPECT_TRUE(d.get(3, 4));
    EXPECT_TRUE(d.toggle(3, 4));
    EXPECT_FALSE(d.get(3, 4));
}

TEST(Display, CoordinatesWrap) {
    Display d;
    d.toggle(64, 32);
    EXPECT_TRUE(d.get(0, 0));
    d.toggle(63, 31);
    const std::string s = d.to_string();
    EXPECT_EQ(s[0], '#');
    EXPECT_EQ(s[31 * 65 + 63], '#');
}

TEST(Display, Clear) {
    Display d;
    d.toggle(1, 1);
    d.clear();
    EXPECT_EQ(d, Display{});
}
