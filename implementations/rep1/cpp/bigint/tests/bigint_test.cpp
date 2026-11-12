#include "bigint/bigint.hpp"

#include <gtest/gtest.h>

#include <random>
#include <sstream>

using bigint::ArithmeticError;
using bigint::BigInt;

namespace {
BigInt B(const char* s) { return BigInt(std::string_view(s)); }
}  // namespace

TEST(BigInt, ParsingAndPrinting) {
  EXPECT_EQ(B("007").to_string(), "7");
  EXPECT_EQ(B("-000123").to_string(), "-123");
  EXPECT_EQ(B("-0").to_string(), "0");
  EXPECT_EQ(B("-000").to_string(), "0");
  EXPECT_FALSE(B("-0").is_negative());
  EXPECT_THROW(BigInt(std::string_view("")), std::invalid_argument);
  EXPECT_THROW(BigInt(std::string_view("-")), std::invalid_argument);
  EXPECT_THROW(BigInt(std::string_view("1x")), std::invalid_argument);
  EXPECT_THROW(BigInt(std::string_view("+1")), std::invalid_argument);
}

TEST(BigInt, MachineIntegerConstruction) {
  EXPECT_EQ(BigInt(0).to_string(), "0");
  EXPECT_EQ(BigInt(-42).to_string(), "-42");
  EXPECT_EQ(BigInt(INT64_MIN).to_string(), "-9223372036854775808");
  EXPECT_EQ(BigInt(INT64_MAX).to_string(), "9223372036854775807");
}

TEST(BigInt, AddSubSigns) {
  EXPECT_EQ(B("12") + B("30"), BigInt(42));
  EXPECT_EQ(B("5") - B("7"), BigInt(-2));
  EXPECT_EQ(B("-5") + B("5"), BigInt(0));
  EXPECT_EQ((B("-5") + B("5")).to_string(), "0");
  EXPECT_EQ(B("-5") - B("-7"), BigInt(2));
  EXPECT_EQ(B("-5") - B("7"), BigInt(-12));
  EXPECT_EQ(B("99999999999999999999") + BigInt(1), B("100000000000000000000"));
  BigInt x = B("123456789012345678901234567890");
  EXPECT_EQ(x - x, BigInt(0));
  x += x;
  EXPECT_EQ(x, B("246913578024691357802469135780"));
}

TEST(BigInt, Multiplication) {
  EXPECT_EQ((B("-123456789012345678901234567890") * B("987654321098765432109876543210")).to_string(),
            "-121932631137021795226185032733622923332237463801111263526900");
  EXPECT_EQ((B("-5") * BigInt(0)).to_string(), "0");
  BigInt x = B("-99999999999999999999");
  EXPECT_EQ(x * x, B("9999999999999999999800000000000000000001"));
}

TEST(BigInt, DivisionSemantics) {
  struct Case { int a, b, q, r; };
  for (Case c : {Case{7, 2, 3, 1}, {-7, 2, -3, -1}, {7, -2, -3, 1}, {-7, -2, 3, -1},
                 {-1, 3, 0, -1}, {-1, 2, 0, -1}, {0, 5, 0, 0}, {-7, 7, -1, 0}}) {
    auto [q, r] = BigInt::divmod(BigInt(c.a), BigInt(c.b));
    EXPECT_EQ(q, BigInt(c.q)) << c.a << "/" << c.b;
    EXPECT_EQ(r, BigInt(c.r)) << c.a << "%" << c.b;
    EXPECT_FALSE(q.is_negative() && q.is_zero());
  }
}

TEST(BigInt, DivisionByZeroThrows) {
  EXPECT_THROW(BigInt(1) / BigInt(0), ArithmeticError);
  EXPECT_THROW(BigInt(0) % BigInt(0), ArithmeticError);
  EXPECT_THROW(BigInt::divmod(BigInt(5), B("-0")), ArithmeticError);
}

TEST(BigInt, DivisionRandomisedIdentity) {
  std::mt19937_64 rng(12345);
  auto random_number = [&](int digits) {
    std::string s;
    // Mix in runs of 9s and 0s to provoke estimate corrections.
    while (static_cast<int>(s.size()) < digits) {
      switch (rng() % 4) {
        case 0: s.append(rng() % 20 + 1, '9'); break;
        case 1: s.append(rng() % 20 + 1, '0'); break;
        default: s.push_back(static_cast<char>('0' + rng() % 10));
      }
    }
    s[0] = static_cast<char>('1' + rng() % 9);
    return BigInt(std::string_view(s));
  };
  for (int i = 0; i < 2000; ++i) {
    BigInt a = random_number(1 + rng() % 200), b = random_number(1 + rng() % 100);
    if (rng() & 1) a = -a;
    if (rng() & 1) b = -b;
    auto [q, r] = BigInt::divmod(a, b);
    ASSERT_EQ(q * b + r, a) << a << " / " << b;
    ASSERT_LT(r.abs(), b.abs()) << a << " / " << b;
    ASSERT_TRUE(r.is_zero() || r.is_negative() == a.is_negative());
  }
}

TEST(BigInt, Comparison) {
  EXPECT_TRUE(B("-3") < B("-2"));
  EXPECT_TRUE(B("007") == B("7"));
  EXPECT_TRUE(B("-0") == B("0"));
  EXPECT_TRUE(B("-100") < B("1"));
  EXPECT_TRUE(B("100") > B("99"));
  EXPECT_TRUE(B("-100") < B("-99"));
}

TEST(BigInt, Power) {
  EXPECT_EQ(BigInt::pow(BigInt(2), 10), BigInt(1024));
  EXPECT_EQ(BigInt::pow(BigInt(0), 0), BigInt(1));
  EXPECT_EQ(BigInt::pow(BigInt(0), 7), BigInt(0));
  EXPECT_EQ(BigInt::pow(BigInt(-2), 3), BigInt(-8));
  EXPECT_EQ(BigInt::pow(BigInt(-2), 2), BigInt(4));
  EXPECT_EQ(BigInt::pow(BigInt(-1), 999), BigInt(-1));
  EXPECT_EQ(BigInt::pow(BigInt(5), B("-0")), BigInt(1));
  EXPECT_THROW(BigInt::pow(BigInt(2), BigInt(-1)), ArithmeticError);
  EXPECT_EQ(BigInt::pow(BigInt(1), B("100000000000000000000000000000")), BigInt(1));
  EXPECT_EQ(BigInt::pow(BigInt(-1), B("100000000000000000000000000001")), BigInt(-1));
  EXPECT_EQ(BigInt::pow(BigInt(0), B("100000000000000000000000000001")), BigInt(0));
  EXPECT_THROW(BigInt::pow(BigInt(2), B("100000000000000000000000000000")), ArithmeticError);
}

TEST(BigInt, LargeOperands) {
  std::string nines(50000, '9');
  BigInt a = BigInt(std::string_view(nines));
  BigInt one(1);
  EXPECT_EQ((a + one).to_string(), "1" + std::string(50000, '0'));
  BigInt sq = a * a;  // (10^n - 1)^2 = 10^2n - 2*10^n + 1
  EXPECT_EQ(sq.to_string(), std::string(49999, '9') + "8" + std::string(49999, '0') + "1");
  auto [q, r] = BigInt::divmod(sq, a);
  EXPECT_EQ(q, a);
  EXPECT_TRUE(r.is_zero());
}

TEST(BigInt, Streaming) {
  std::ostringstream os;
  os << B("-0012");
  EXPECT_EQ(os.str(), "-12");
}
