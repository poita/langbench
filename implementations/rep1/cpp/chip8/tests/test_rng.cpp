#include <gtest/gtest.h>

#include "chip8/rng.hpp"

using chip8::Rng;

TEST(Rng, DefaultSeed) { EXPECT_EQ(Rng().state(), 0x12345678u); }

TEST(Rng, MatchesSpecSequence) {
  Rng rng;
  EXPECT_EQ(rng.next_byte(), 0x71);
  EXPECT_EQ(rng.state(), 0x0b719151u);
  EXPECT_EQ(rng.next_byte(), 0x47);
  EXPECT_EQ(rng.state(), 0x6f47bdb6u);
  EXPECT_EQ(rng.next_byte(), 0x1d);
  EXPECT_EQ(rng.state(), 0x2e1d6ab7u);
}

TEST(Rng, CustomSeedAndWraparound) {
  Rng rng(0xFFFFFFFFu);
  rng.next_byte();
  EXPECT_EQ(rng.state(), static_cast<std::uint32_t>(0xFFFFFFFFu * 1103515245u + 12345u));
}
