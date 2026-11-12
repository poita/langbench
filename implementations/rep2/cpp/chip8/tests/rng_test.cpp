#include <gtest/gtest.h>

#include "chip8/rng.hpp"

using chip8::Rng;

TEST(Rng, MatchesSpecSequence) {
    Rng r;
    EXPECT_EQ(r.next_byte(), 0x71);
    EXPECT_EQ(r.state(), 0x0b719151u);
    EXPECT_EQ(r.next_byte(), 0x47);
    EXPECT_EQ(r.state(), 0x6f47bdb6u);
    EXPECT_EQ(r.next_byte(), 0x1d);
    EXPECT_EQ(r.state(), 0x2e1d6ab7u);
}

TEST(Rng, CustomSeed) {
    Rng r(0);
    EXPECT_EQ(r.next_byte(), (12345u >> 16) & 0xFF);
    EXPECT_EQ(r.state(), 12345u);
}
