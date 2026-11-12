#include <gtest/gtest.h>

#include "softfloat/softfloat.h"

namespace sf = softfloat;
using sf::Bits32;
using sf::kQuietNaN;

TEST(Examples, Basic) {
  EXPECT_EQ(sf::add(0x3f800000, 0x3f800000), 0x40000000u);
  EXPECT_EQ(sf::sub(0x3f800000, 0x3f800000), 0x00000000u);
  EXPECT_EQ(sf::mul(0x40400000, 0xc0400000), 0xc1100000u);
  EXPECT_EQ(sf::div(0x3f800000, 0x40400000), 0x3eaaaaabu);
  EXPECT_EQ(sf::sqrt(0x40000000), 0x3fb504f3u);
}

TEST(Rounding, OverflowBoundary) {
  EXPECT_EQ(sf::add(0x7f7fffff, 0x73000000), 0x7f800000u);  // exactly the midpoint -> inf
  EXPECT_EQ(sf::add(0x7f7fffff, 0x72ffffff), 0x7f7fffffu);
  EXPECT_EQ(sf::mul(0x7f7fffff, 0x40000000), 0x7f800000u);
  EXPECT_EQ(sf::div(0x7f7fffff, 0x3f000000), 0x7f800000u);
  EXPECT_EQ(sf::mul(0xff7fffff, 0x40000000), 0xff800000u);
}

TEST(Rounding, TiesToEven) {
  EXPECT_EQ(sf::add(0x3f800000, 0x33800000), 0x3f800000u);
  EXPECT_EQ(sf::add(0x3f800001, 0x33800000), 0x3f800002u);
  EXPECT_EQ(sf::add(0x3f800000, 0x33000000), 0x3f800000u);
}

TEST(Rounding, Denormals) {
  EXPECT_EQ(sf::div(0x00000001, 0x40000000), 0x00000000u);  // tie to even (0)
  EXPECT_EQ(sf::div(0x00000003, 0x40000000), 0x00000002u);
  EXPECT_EQ(sf::mul(0x00000001, 0x3f000000), 0x00000000u);
  EXPECT_EQ(sf::mul(0x80000001, 0x3f000000), 0x80000000u);
  EXPECT_EQ(sf::mul(0x00000001, 0x3f400000), 0x00000001u);
  // Largest denormal + smallest denormal = smallest normal.
  EXPECT_EQ(sf::add(0x007fffff, 0x00000001), 0x00800000u);
  // Smallest normal - smallest denormal = largest denormal (exact).
  EXPECT_EQ(sf::sub(0x00800000, 0x00000001), 0x007fffffu);
  // Rounding up out of the denormal range lands on the smallest normal.
  EXPECT_EQ(sf::mul(0x007fffff, 0x3f800001), 0x00800000u);
  EXPECT_EQ(sf::sqrt(0x00000001), 0x1a3504f3u);
}

TEST(Rounding, SqrtExact) {
  EXPECT_EQ(sf::sqrt(0x3f800000), 0x3f800000u);
  EXPECT_EQ(sf::sqrt(0x40800000), 0x40000000u);
  EXPECT_EQ(sf::sqrt(0x41100000), 0x40400000u);  // sqrt(9) = 3
  EXPECT_EQ(sf::sqrt(0x7f7fffff), 0x5f7fffffu);
}

TEST(Rounding, DivExact) {
  EXPECT_EQ(sf::div(0x41100000, 0x40400000), 0x40400000u);  // 9/3
  EXPECT_EQ(sf::div(0x00800000, 0x3f800000), 0x00800000u);
  EXPECT_EQ(sf::div(0x007fffff, 0x007fffff), 0x3f800000u);
  EXPECT_EQ(sf::div(0x00000001, 0x00000001), 0x3f800000u);
  EXPECT_EQ(sf::div(0x7f7fffff, 0x00000001), 0x7f800000u);
  EXPECT_EQ(sf::div(0x00000001, 0x7f7fffff), 0x00000000u);
}
