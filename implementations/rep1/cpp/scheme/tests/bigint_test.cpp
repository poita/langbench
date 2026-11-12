#include <gtest/gtest.h>

#include "scheme/bigint.hpp"

using scheme::BigInt;

namespace {
BigInt D(const char* s) { return BigInt::from_decimal(s); }
}  // namespace

TEST(BigInt, ZeroAndSmallValues) {
  EXPECT_EQ(BigInt().to_string(), "0");
  EXPECT_EQ(BigInt(-42).to_string(), "-42");
  EXPECT_EQ(D("-0").to_string(), "0");
  EXPECT_FALSE(D("-0").is_negative());
  EXPECT_EQ(D("+007").to_string(), "7");
}

TEST(BigInt, Int64Boundaries) {
  EXPECT_TRUE(BigInt(INT64_MIN).fits_int64());
  EXPECT_EQ(BigInt(INT64_MIN).to_int64(), INT64_MIN);
  EXPECT_EQ(BigInt(INT64_MIN).to_string(), "-9223372036854775808");
  EXPECT_TRUE(D("9223372036854775807").fits_int64());
  EXPECT_FALSE(D("9223372036854775808").fits_int64());
  EXPECT_TRUE(D("-9223372036854775808").fits_int64());
  EXPECT_FALSE(D("-9223372036854775809").fits_int64());
}

TEST(BigInt, DecimalRoundTrip) {
  const char* s = "123456789012345678901234567890123456789012345678901234567890";
  EXPECT_EQ(D(s).to_string(), s);
  EXPECT_EQ(D("1000000000000000000000").to_string(), "1000000000000000000000");
}

TEST(BigInt, AddSubtract) {
  EXPECT_EQ((D("99999999999999999999") + BigInt(1)).to_string(), "100000000000000000000");
  EXPECT_EQ((D("100000000000000000000") - BigInt(1)).to_string(), "99999999999999999999");
  EXPECT_EQ((BigInt(5) - D("100000000000000000000")).to_string(), "-99999999999999999995");
  EXPECT_TRUE((D("12345678901234567890") - D("12345678901234567890")).is_zero());
  EXPECT_EQ((D("-7") + D("3")).to_string(), "-4");
}

TEST(BigInt, Multiply) {
  EXPECT_EQ((D("4294967296") * D("4294967296")).to_string(), "18446744073709551616");
  EXPECT_EQ((D("-12345678901234567890") * D("98765432109876543210")).to_string(),
            "-1219326311370217952237463801111263526900");
  EXPECT_TRUE((D("123456789123456789123") * BigInt(0)).is_zero());
}

TEST(BigInt, DivisionTruncatesTowardZero) {
  BigInt q, r;
  BigInt::divmod(BigInt(-7), BigInt(2), q, r);
  EXPECT_EQ(q.to_string(), "-3");
  EXPECT_EQ(r.to_string(), "-1");
  BigInt::divmod(BigInt(7), BigInt(-2), q, r);
  EXPECT_EQ(q.to_string(), "-3");
  EXPECT_EQ(r.to_string(), "1");
}

TEST(BigInt, DivisionMultiLimb) {
  BigInt a = D("1219326311370217952237463801111263526900");
  BigInt b = D("98765432109876543210");
  BigInt q, r;
  BigInt::divmod(a, b, q, r);
  EXPECT_EQ(q.to_string(), "12345678901234567890");
  EXPECT_TRUE(r.is_zero());
  BigInt::divmod(a + BigInt(17), b, q, r);
  EXPECT_EQ(q.to_string(), "12345678901234567890");
  EXPECT_EQ(r.to_string(), "17");
}

TEST(BigInt, DivisionIdentityOnLargeValues) {
  // Exercises the add-back step of Algorithm D with awkward limb patterns.
  BigInt a = D("340282366920938463463374607431768211455");   // 2^128 - 1
  BigInt b = D("18446744073709551615");                      // 2^64 - 1
  BigInt q, r;
  BigInt::divmod(a, b, q, r);
  EXPECT_EQ((q * b + r), a);
  EXPECT_TRUE(r < b);
  BigInt c = D("79228162514264337589248983040");  // 0xFFFFFFFF * 2^64 + 0x80000000 * 2^32-ish
  BigInt d = D("4294967297");
  BigInt::divmod(c, d, q, r);
  EXPECT_EQ((q * d + r), c);
  EXPECT_TRUE(r < d);
}

TEST(BigInt, Comparison) {
  EXPECT_LT(D("-100000000000000000000"), BigInt(0));
  EXPECT_GT(D("100000000000000000001"), D("100000000000000000000"));
  EXPECT_EQ(D("5"), BigInt(5));
  EXPECT_LT(D("-5"), D("-4"));
}

TEST(BigInt, Factorial) {
  BigInt f(1);
  for (int i = 2; i <= 30; ++i) f = f * BigInt(i);
  EXPECT_EQ(f.to_string(), "265252859812191058636308480000000");
  BigInt back = f;
  for (int i = 30; i >= 2; --i) {
    BigInt q, r;
    BigInt::divmod(back, BigInt(i), q, r);
    EXPECT_TRUE(r.is_zero());
    back = q;
  }
  EXPECT_EQ(back, BigInt(1));
}
