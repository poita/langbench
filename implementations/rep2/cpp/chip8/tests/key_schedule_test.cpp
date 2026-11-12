#include <gtest/gtest.h>

#include <stdexcept>

#include "chip8/key_schedule.hpp"

using chip8::parse_key_schedule;

TEST(KeySchedule, Empty) { EXPECT_TRUE(parse_key_schedule("").empty()); }

TEST(KeySchedule, ParsesEvents) {
    auto k = parse_key_schedule("0:0001 9:0300 4000000000:ffff");
    ASSERT_EQ(k.size(), 3u);
    EXPECT_EQ(k[0].cycle, 0u);
    EXPECT_EQ(k[0].mask, 0x0001);
    EXPECT_EQ(k[1].cycle, 9u);
    EXPECT_EQ(k[1].mask, 0x0300);
    EXPECT_EQ(k[2].cycle, 4000000000u);
    EXPECT_EQ(k[2].mask, 0xffff);
}

TEST(KeySchedule, RejectsMalformed) {
    EXPECT_THROW(parse_key_schedule("5"), std::invalid_argument);
    EXPECT_THROW(parse_key_schedule("5:12"), std::invalid_argument);
    EXPECT_THROW(parse_key_schedule("x:0000"), std::invalid_argument);
    EXPECT_THROW(parse_key_schedule("5:00zz"), std::invalid_argument);
    EXPECT_THROW(parse_key_schedule("5:0000 5:0001"), std::invalid_argument);
    EXPECT_THROW(parse_key_schedule("5:0000 4:0001"), std::invalid_argument);
}
