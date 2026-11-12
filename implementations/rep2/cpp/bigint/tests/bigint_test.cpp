#include <gtest/gtest.h>

#include <cstdint>
#include <random>
#include <sstream>

#include "bigint/bigint.hpp"

using bigint::BigInt;

TEST(BigInt, ParsingNormalises) {
    EXPECT_EQ(BigInt("007").to_string(), "7");
    EXPECT_EQ(BigInt("-000123").to_string(), "-123");
    EXPECT_EQ(BigInt("-0").to_string(), "0");
    EXPECT_EQ(BigInt("-000").to_string(), "0");
    EXPECT_FALSE(BigInt("-0").is_negative());
    EXPECT_EQ(BigInt("-0").sign(), 0);
}

TEST(BigInt, ParseErrors) {
    EXPECT_THROW(BigInt(""), bigint::ParseError);
    EXPECT_THROW(BigInt("-"), bigint::ParseError);
    EXPECT_THROW(BigInt("+5"), bigint::ParseError);
    EXPECT_THROW(BigInt("12a"), bigint::ParseError);
    EXPECT_THROW(BigInt("1 2"), bigint::ParseError);
}

TEST(BigInt, FromInt64) {
    EXPECT_EQ(BigInt(0).to_string(), "0");
    EXPECT_EQ(BigInt(-42).to_string(), "-42");
    EXPECT_EQ(BigInt(INT64_MIN).to_string(), "-9223372036854775808");
    EXPECT_EQ(BigInt(INT64_MAX).to_string(), "9223372036854775807");
}

TEST(BigInt, ToUint64) {
    EXPECT_EQ(BigInt("18446744073709551615").to_uint64(), UINT64_MAX);
    EXPECT_THROW(BigInt("18446744073709551616").to_uint64(), std::overflow_error);
    EXPECT_THROW(BigInt("-1").to_uint64(), std::overflow_error);
    EXPECT_EQ(BigInt("0").to_uint64(), 0u);
}

TEST(BigInt, AddSubSigns) {
    EXPECT_EQ((BigInt(5) - BigInt(7)).to_string(), "-2");
    EXPECT_EQ((BigInt(-5) + BigInt(5)).to_string(), "0");
    EXPECT_EQ((BigInt(-5) - BigInt(-7)).to_string(), "2");
    EXPECT_EQ((BigInt("-0") + BigInt(0)).to_string(), "0");
    EXPECT_EQ((BigInt("99999999999999999999") + BigInt(1)).to_string(), "100000000000000000000");
}

TEST(BigInt, MulSigns) {
    EXPECT_EQ((BigInt(-5) * BigInt(0)).to_string(), "0");
    EXPECT_FALSE((BigInt(-5) * BigInt(0)).is_negative());
    EXPECT_EQ((BigInt(-3) * BigInt(-4)).to_string(), "12");
    EXPECT_EQ((BigInt(-3) * BigInt(4)).to_string(), "-12");
}

TEST(BigInt, DivisionTruncatesTowardZero) {
    struct Case { int a, b, q, r; };
    for (Case c : {Case{7, 2, 3, 1}, {-7, 2, -3, -1}, {7, -2, -3, 1}, {-7, -2, 3, -1},
                   {-1, 3, 0, -1}, {-1, 2, 0, -1}, {-7, 7, -1, 0}, {0, 5, 0, 0}}) {
        auto [q, r] = BigInt::divmod(BigInt(c.a), BigInt(c.b));
        EXPECT_EQ(q, BigInt(c.q)) << c.a << "/" << c.b;
        EXPECT_EQ(r, BigInt(c.r)) << c.a << "%" << c.b;
        EXPECT_FALSE(q.is_negative() && q.is_zero());
        EXPECT_FALSE(r.is_negative() && r.is_zero());
    }
}

TEST(BigInt, DivisionByZeroThrows) {
    EXPECT_THROW(BigInt(1) / BigInt(0), std::domain_error);
    EXPECT_THROW(BigInt(0) % BigInt(0), std::domain_error);
}

TEST(BigInt, Pow) {
    EXPECT_EQ(BigInt::pow(BigInt(-2), 3).to_string(), "-8");
    EXPECT_EQ(BigInt::pow(BigInt(-2), 2).to_string(), "4");
    EXPECT_EQ(BigInt::pow(BigInt(0), 0).to_string(), "1");
    EXPECT_EQ(BigInt::pow(BigInt(0), 7).to_string(), "0");
    EXPECT_EQ(BigInt::pow(BigInt(-1), 999).to_string(), "-1");
    EXPECT_EQ(BigInt::pow(BigInt(2), 100).to_string(), "1267650600228229401496703205376");
}

TEST(BigInt, Compare) {
    EXPECT_LT(BigInt(-3), BigInt(-2));
    EXPECT_GT(BigInt(1), BigInt(-100));
    EXPECT_EQ(BigInt("-0"), BigInt("0"));
    EXPECT_EQ(BigInt("007"), BigInt(7));
    EXPECT_LE(BigInt(7), BigInt(7));
    EXPECT_NE(BigInt(7), BigInt(8));
}

TEST(BigInt, Stream) {
    std::ostringstream os;
    os << BigInt("-12345678901234567890");
    EXPECT_EQ(os.str(), "-12345678901234567890");
}

TEST(BigInt, MatchesMachineArithmeticOnRandomValues) {
    std::mt19937_64 rng(2024);
    for (int t = 0; t < 20000; ++t) {
        const std::int64_t x = static_cast<std::int32_t>(rng());
        const std::int64_t y = static_cast<std::int32_t>(rng());
        const BigInt a(x), b(y);
        ASSERT_EQ(a + b, BigInt(x + y));
        ASSERT_EQ(a - b, BigInt(x - y));
        ASSERT_EQ(a * b, BigInt(x * y));
        if (y != 0) {
            ASSERT_EQ(a / b, BigInt(x / y));
            ASSERT_EQ(a % b, BigInt(x % y));
        }
        ASSERT_EQ(BigInt::compare(a, b), x < y ? -1 : x > y ? 1 : 0);
    }
}

TEST(BigInt, DivisionIdentityOnLargeValues) {
    std::mt19937_64 rng(99);
    auto rnd = [&](std::size_t len) {
        std::string s = (rng() & 1) ? "-" : "";
        for (std::size_t i = 0; i < len; ++i) s += static_cast<char>('0' + rng() % 10);
        return BigInt(s);
    };
    for (int t = 0; t < 300; ++t) {
        const BigInt a = rnd(1 + rng() % 600);
        const BigInt b = rnd(1 + rng() % 300);
        if (b.is_zero()) continue;
        auto [q, r] = BigInt::divmod(a, b);
        ASSERT_EQ(q * b + r, a);
        ASSERT_LT(r.abs(), b.abs());
        ASSERT_TRUE(r.is_zero() || r.is_negative() == a.is_negative());
    }
}
