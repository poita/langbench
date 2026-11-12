#include <gtest/gtest.h>

#include "softfloat/softfloat.h"

namespace sf = softfloat;
using sf::Bits32;
using sf::kQuietNaN;

namespace {
constexpr Bits32 kOne = 0x3f800000, kMinusOne = 0xbf800000, kPZero = 0, kNZero = 0x80000000;
constexpr Bits32 kPInf = 0x7f800000, kNInf = 0xff800000;
constexpr Bits32 kSNaN = 0x7f800001, kNegNaN = 0xffc12345;
}  // namespace

TEST(Nan, AnyNanOperandGivesCanonicalQuietNan) {
  for (Bits32 n : {kSNaN, kNegNaN, 0x7fc00000u, 0xffffffffu}) {
    EXPECT_EQ(sf::add(n, kOne), kQuietNaN);
    EXPECT_EQ(sf::add(kOne, n), kQuietNaN);
    EXPECT_EQ(sf::sub(kOne, n), kQuietNaN);
    EXPECT_EQ(sf::mul(n, kPInf), kQuietNaN);
    EXPECT_EQ(sf::div(kOne, n), kQuietNaN);
    EXPECT_EQ(sf::sqrt(n), kQuietNaN);
  }
}

TEST(Nan, InvalidOperations) {
  EXPECT_EQ(sf::add(kPInf, kNInf), kQuietNaN);
  EXPECT_EQ(sf::add(kNInf, kPInf), kQuietNaN);
  EXPECT_EQ(sf::sub(kPInf, kPInf), kQuietNaN);
  EXPECT_EQ(sf::sub(kNInf, kNInf), kQuietNaN);
  EXPECT_EQ(sf::mul(kPInf, kPZero), kQuietNaN);
  EXPECT_EQ(sf::mul(kNZero, kNInf), kQuietNaN);
  EXPECT_EQ(sf::div(kPZero, kNZero), kQuietNaN);
  EXPECT_EQ(sf::div(kPInf, kNInf), kQuietNaN);
  EXPECT_EQ(sf::sqrt(kMinusOne), kQuietNaN);
  EXPECT_EQ(sf::sqrt(kNInf), kQuietNaN);
  EXPECT_EQ(sf::sqrt(0x80000001), kQuietNaN);
}

TEST(Infinity, Arithmetic) {
  EXPECT_EQ(sf::add(kPInf, kOne), kPInf);
  EXPECT_EQ(sf::add(kOne, kNInf), kNInf);
  EXPECT_EQ(sf::sub(kOne, kPInf), kNInf);
  EXPECT_EQ(sf::add(kNInf, kNInf), kNInf);
  EXPECT_EQ(sf::sub(kPInf, kNInf), kPInf);
  EXPECT_EQ(sf::mul(kPInf, kMinusOne), kNInf);
  EXPECT_EQ(sf::div(kPInf, kMinusOne), kNInf);
  EXPECT_EQ(sf::div(kOne, kNInf), kNZero);
  EXPECT_EQ(sf::div(kNZero, kPInf), kNZero);
  EXPECT_EQ(sf::div(kOne, kNZero), kNInf);
  EXPECT_EQ(sf::div(kOne, kPZero), kPInf);
  EXPECT_EQ(sf::sqrt(kPInf), kPInf);
}

TEST(SignedZero, AddSub) {
  EXPECT_EQ(sf::add(kNZero, kNZero), kNZero);
  EXPECT_EQ(sf::add(kNZero, kPZero), kPZero);
  EXPECT_EQ(sf::add(kPZero, kNZero), kPZero);
  EXPECT_EQ(sf::sub(kNZero, kPZero), kNZero);
  EXPECT_EQ(sf::sub(kNZero, kNZero), kPZero);
  EXPECT_EQ(sf::sub(kOne, kOne), kPZero);
  EXPECT_EQ(sf::add(kOne, kMinusOne), kPZero);
  EXPECT_EQ(sf::add(kNZero, kOne), kOne);
  EXPECT_EQ(sf::sub(kPZero, 0x80000001), 0x00000001u);
}

TEST(SignedZero, MulDivSqrt) {
  EXPECT_EQ(sf::mul(kPZero, kMinusOne), kNZero);
  EXPECT_EQ(sf::mul(kNZero, kNZero), kPZero);
  EXPECT_EQ(sf::div(kPZero, 0xc0400000), kNZero);
  EXPECT_EQ(sf::sqrt(kPZero), kPZero);
  EXPECT_EQ(sf::sqrt(kNZero), kNZero);
}
