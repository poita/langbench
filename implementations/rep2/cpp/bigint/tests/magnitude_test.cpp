#include <gtest/gtest.h>

#include <random>
#include <string>

#include "bigint/magnitude.hpp"

using namespace bigint::mag;

namespace {
Magnitude M(const std::string& s) { return from_digits(s); }

std::string random_digits(std::mt19937_64& rng, std::size_t len) {
    std::string s;
    for (std::size_t i = 0; i < len; ++i) s += static_cast<char>('0' + rng() % 10);
    return s;
}
// Digits biased toward 0 and 9 to provoke carries, borrows and qhat corrections.
std::string edgy_digits(std::mt19937_64& rng, std::size_t len) {
    std::string s;
    for (std::size_t i = 0; i < len; ++i) {
        const auto r = rng() % 4;
        s += r == 0 ? '0' : r == 1 ? '9' : static_cast<char>('0' + rng() % 10);
    }
    return s;
}
}  // namespace

TEST(Magnitude, ParseAndPrint) {
    EXPECT_TRUE(M("0").empty());
    EXPECT_TRUE(M("0000000000000").empty());
    EXPECT_EQ(to_string(M("")), "0");
    EXPECT_EQ(to_string(M("000123")), "123");
    EXPECT_EQ(to_string(M("1000000000")), "1000000000");
    EXPECT_EQ(to_string(M("123456789012345678901234567890")), "123456789012345678901234567890");
    EXPECT_EQ(M("1000000000").size(), 2u);
}

TEST(Magnitude, AddSubCarry) {
    EXPECT_EQ(to_string(add(M("999999999"), M("1"))), "1000000000");
    EXPECT_EQ(to_string(add(M("999999999999999999"), M("999999999999999999"))),
              "1999999999999999998");
    EXPECT_EQ(to_string(sub(M("1000000000000000000"), M("1"))), "999999999999999999");
    EXPECT_EQ(to_string(sub(M("12345"), M("12345"))), "0");
}

TEST(Magnitude, Compare) {
    EXPECT_EQ(compare(M("5"), M("5")), 0);
    EXPECT_EQ(compare(M("5"), M("6")), -1);
    EXPECT_EQ(compare(M("1000000000"), M("999999999")), 1);
    EXPECT_EQ(compare(M("0"), M("1")), -1);
}

TEST(Magnitude, Mul) {
    EXPECT_EQ(to_string(mul(M("0"), M("123"))), "0");
    EXPECT_EQ(to_string(mul(M("999999999"), M("999999999"))), "999999998000000001");
    EXPECT_EQ(to_string(mul(M("123456789012345678901234567890"), M("987654321098765432109876543210"))),
              "121932631137021795226185032733622923332237463801111263526900");
}

TEST(Magnitude, SquareMatchesMul) {
    std::mt19937_64 rng(1);
    for (int t = 0; t < 200; ++t) {
        const Magnitude a = M(edgy_digits(rng, 1 + rng() % 300));
        EXPECT_EQ(square(a), mul(a, a));
    }
    EXPECT_TRUE(square({}).empty());
}

TEST(Magnitude, DivModBasics) {
    auto r = divmod(M("100"), M("7"));
    EXPECT_EQ(to_string(r.quotient), "14");
    EXPECT_EQ(to_string(r.remainder), "2");
    r = divmod(M("5"), M("100"));
    EXPECT_EQ(to_string(r.quotient), "0");
    EXPECT_EQ(to_string(r.remainder), "5");
    EXPECT_THROW(divmod(M("5"), M("0")), std::domain_error);
}

TEST(Magnitude, DivModKnuthAddBackCase) {
    // Classic inputs that force the "add back" step in base 2^k; in base 10^9
    // we use near-boundary limbs to hit qhat corrections.
    const Magnitude b = M("999999999999999999999999999");           // 3 limbs of 999999999
    const Magnitude a = mul(b, M("999999999999999999")) ;
    auto r = divmod(a, b);
    EXPECT_EQ(to_string(r.quotient), "999999999999999999");
    EXPECT_TRUE(r.remainder.empty());
    auto r2 = divmod(sub(a, M("1")), b);
    EXPECT_EQ(to_string(r2.quotient), "999999999999999998");
    EXPECT_EQ(to_string(r2.remainder), "999999999999999999999999998");
}

TEST(Magnitude, DivModRandomIdentity) {
    std::mt19937_64 rng(42);
    for (int t = 0; t < 3000; ++t) {
        const Magnitude b = M(edgy_digits(rng, 1 + rng() % 120));
        if (b.empty()) continue;
        const Magnitude a = M(edgy_digits(rng, 1 + rng() % 300));
        const auto r = divmod(a, b);
        EXPECT_LT(compare(r.remainder, b), 0);
        EXPECT_EQ(add(mul(r.quotient, b), r.remainder), a);
    }
}

TEST(Magnitude, DivModExactMultiples) {
    std::mt19937_64 rng(7);
    for (int t = 0; t < 500; ++t) {
        const Magnitude b = M("1" + edgy_digits(rng, rng() % 100));
        const Magnitude q = M("1" + edgy_digits(rng, rng() % 100));
        const auto r = divmod(mul(b, q), b);
        EXPECT_EQ(r.quotient, q);
        EXPECT_TRUE(r.remainder.empty());
        const auto r2 = divmod(sub(mul(b, q), M("1")), b);
        EXPECT_EQ(add(mul(r2.quotient, b), r2.remainder), sub(mul(b, q), M("1")));
    }
}

TEST(Magnitude, Pow) {
    EXPECT_EQ(to_string(pow(M("2"), 10)), "1024");
    EXPECT_EQ(to_string(pow(M("0"), 0)), "1");
    EXPECT_EQ(to_string(pow(M("0"), 5)), "0");
    EXPECT_EQ(to_string(pow(M("10"), 30)), "1" + std::string(30, '0'));
    EXPECT_EQ(to_string(pow(M("3"), 100)), "515377520732011331036461129765621272702107522001");
}
