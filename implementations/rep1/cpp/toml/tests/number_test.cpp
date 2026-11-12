#include <gtest/gtest.h>

#include <cmath>
#include <limits>

#include "toml/number.hpp"

using toml::canonical_float;
using toml::canonical_integer;

TEST(Integer, DecimalForms) {
  EXPECT_EQ(canonical_integer("0"), "0");
  EXPECT_EQ(canonical_integer("+0"), "0");
  EXPECT_EQ(canonical_integer("-0"), "0");
  EXPECT_EQ(canonical_integer("42"), "42");
  EXPECT_EQ(canonical_integer("+99"), "99");
  EXPECT_EQ(canonical_integer("-17"), "-17");
  EXPECT_EQ(canonical_integer("1_000"), "1000");
}

TEST(Integer, PrefixedForms) {
  EXPECT_EQ(canonical_integer("0xDEADbeef"), "3735928559");
  EXPECT_EQ(canonical_integer("0o755"), "493");
  EXPECT_EQ(canonical_integer("0b1101_0110"), "214");
  EXPECT_EQ(canonical_integer("0x0"), "0");
}

TEST(Integer, RangeIsSigned64Bit) {
  EXPECT_EQ(canonical_integer("9223372036854775807"), "9223372036854775807");
  EXPECT_EQ(canonical_integer("-9223372036854775808"), "-9223372036854775808");
  EXPECT_FALSE(canonical_integer("9223372036854775808"));
  EXPECT_FALSE(canonical_integer("-9223372036854775809"));
  EXPECT_FALSE(canonical_integer("0xFFFFFFFFFFFFFFFF"));
  EXPECT_EQ(canonical_integer("0x7FFFFFFFFFFFFFFF"), "9223372036854775807");
}

TEST(Integer, RejectsMalformed) {
  for (const char* bad : {"", "+", "-", "01", "+01", "1__0", "_1", "1_", "0X1", "-0x1", "0x",
                          "0xg", "0o8", "0b2", "0x_1", "0x1_", "1.0", "12a"})
    EXPECT_FALSE(canonical_integer(bad)) << bad;
}

TEST(Float, CanonicalText) {
  EXPECT_EQ(canonical_float("1.0"), "1.0000000000000000e+00");
  EXPECT_EQ(canonical_float("3.1415"), "3.1415000000000002e+00");
  EXPECT_EQ(canonical_float("-0.0"), "-0.0000000000000000e+00");
  EXPECT_EQ(canonical_float("0e0"), "0.0000000000000000e+00");
  EXPECT_EQ(canonical_float("1e308"), "1.0000000000000000e+308");
  EXPECT_EQ(canonical_float("6.626e-34"), "6.6259999999999998e-34");
  EXPECT_EQ(canonical_float("5e-324"), "4.9406564584124654e-324");
  EXPECT_EQ(canonical_float("1_0.0_1e+0_1"), "1.0009999999999999e+02");
  EXPECT_EQ(canonical_float("0e00"), "0.0000000000000000e+00");
}

TEST(Float, SpecialsAndRange) {
  EXPECT_EQ(canonical_float("inf"), "inf");
  EXPECT_EQ(canonical_float("+inf"), "inf");
  EXPECT_EQ(canonical_float("-inf"), "-inf");
  EXPECT_EQ(canonical_float("nan"), "nan");
  EXPECT_EQ(canonical_float("-nan"), "nan");
  EXPECT_EQ(canonical_float("1e999"), "inf");
  EXPECT_EQ(canonical_float("-1e999"), "-inf");
  EXPECT_EQ(canonical_float("1e-999"), "0.0000000000000000e+00");
}

TEST(Float, RejectsMalformed) {
  for (const char* bad : {"", ".5", "5.", "1.e2", "1e", "1e+", "01.5", "1._5", "1.5_", "Inf", "NAN",
                          "1", "+", "1.5e1.5", "1e1_", "- 1.0"})
    EXPECT_FALSE(canonical_float(bad)) << bad;
}

TEST(Float, FormatFloat) {
  EXPECT_EQ(toml::format_float(0.5), "5.0000000000000000e-01");
  EXPECT_EQ(toml::format_float(std::numeric_limits<double>::quiet_NaN()), "nan");
  EXPECT_EQ(toml::format_float(-std::numeric_limits<double>::infinity()), "-inf");
  EXPECT_EQ(toml::format_float(-std::nan("")), "nan");
}
