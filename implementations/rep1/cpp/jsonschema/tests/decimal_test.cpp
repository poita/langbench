#include <gtest/gtest.h>

#include "jsonschema/decimal.hpp"

using jsonschema::Decimal;

namespace {
Decimal D(const char* s) {
  auto d = Decimal::parse(s);
  EXPECT_TRUE(d.has_value()) << s;
  return d.value_or(Decimal());
}
}  // namespace

TEST(Decimal, ParseRejectsMalformedLiterals) {
  for (const char* s : {"", "-", "1.", ".5", "1e", "1e+", "--1", "1.5.2", "0x10", "1 "}) {
    EXPECT_FALSE(Decimal::parse(s).has_value()) << s;
  }
}

TEST(Decimal, EqualityIsByValue) {
  EXPECT_EQ(D("1"), D("1.0"));
  EXPECT_EQ(D("1"), D("1.00"));
  EXPECT_EQ(D("1"), D("1e0"));
  EXPECT_EQ(D("100"), D("1e2"));
  EXPECT_EQ(D("-0"), D("0"));
  EXPECT_EQ(D("0.0"), D("0e5"));
  EXPECT_NE(D("1"), D("-1"));
  EXPECT_EQ(D("1.5").hash(), D("15e-1").hash());
}

TEST(Decimal, IntegerDetection) {
  EXPECT_TRUE(D("1.0").is_integer());
  EXPECT_TRUE(D("1e2").is_integer());
  EXPECT_TRUE(D("-0").is_integer());
  EXPECT_FALSE(D("1.5").is_integer());
  EXPECT_FALSE(D("1e-1").is_integer());
}

TEST(Decimal, Ordering) {
  EXPECT_GT(D("1e309").compare(D("1e308")), 0);
  EXPECT_LT(D("-1e309").compare(D("-1e308")), 0);
  EXPECT_LT(D("-1").compare(D("0")), 0);
  EXPECT_GT(D("0.001").compare(D("0")), 0);
  EXPECT_LT(D("12").compare(D("123")), 0);
  EXPECT_EQ(D("5").compare(D("5.0")), 0);
  EXPECT_GT(D("0.5").compare(D("0.05")), 0);
}

TEST(Decimal, MultipleOfIsExact) {
  EXPECT_TRUE(D("0.3").is_multiple_of(D("0.0001")));
  EXPECT_TRUE(D("0.0021").is_multiple_of(D("0.0001")));
  EXPECT_FALSE(D("0.00011").is_multiple_of(D("0.0001")));
  EXPECT_TRUE(D("0").is_multiple_of(D("7")));
  EXPECT_TRUE(D("12").is_multiple_of(D("3")));
  EXPECT_FALSE(D("13").is_multiple_of(D("3")));
  EXPECT_TRUE(D("1e308").is_multiple_of(D("0.5")));
  EXPECT_FALSE(D("1.5").is_multiple_of(D("1")));
  EXPECT_TRUE(D("-6").is_multiple_of(D("1.5")));
}

TEST(Decimal, MultipleOfWithLargeDivisors) {
  // 3 * 12345678901234567890123456789 = 37037036703703703670370370367
  EXPECT_TRUE(D("37037036703703703670370370367").is_multiple_of(D("12345678901234567890123456789")));
  EXPECT_FALSE(D("37037036703703703670370370368").is_multiple_of(D("12345678901234567890123456789")));
  EXPECT_TRUE(D("1e400").is_multiple_of(D("1e-400")));
}

TEST(Decimal, ToCount) {
  EXPECT_EQ(D("2").to_count(), 2u);
  EXPECT_EQ(D("2.0").to_count(), 2u);
  EXPECT_EQ(D("2e0").to_count(), 2u);
  EXPECT_EQ(D("0").to_count(), 0u);
  EXPECT_FALSE(D("-1").to_count().has_value());
  EXPECT_FALSE(D("1.5").to_count().has_value());
  EXPECT_EQ(D("1e30").to_count(), UINT64_MAX);
}

TEST(Decimal, ToString) {
  EXPECT_EQ(D("1.50").to_string(), "1.5");
  EXPECT_EQ(D("-0.001").to_string(), "-0.001");
  EXPECT_EQ(D("1e2").to_string(), "100");
  EXPECT_EQ(D("1e400").to_string(), "1e400");
  EXPECT_EQ(D("0").to_string(), "0");
}
