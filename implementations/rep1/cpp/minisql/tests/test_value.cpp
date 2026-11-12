#include <gtest/gtest.h>

#include "minisql/value.hpp"

using minisql::Value;
using minisql::compare;

TEST(Value, NullSortsFirst) {
  EXPECT_EQ(compare(Value::null(), Value::null()), 0);
  EXPECT_LT(compare(Value::null(), Value::integer(-5)), 0);
  EXPECT_GT(compare(Value::text(""), Value::null()), 0);
}

TEST(Value, NumbersBeforeText) {
  EXPECT_LT(compare(Value::integer(100), Value::text("0")), 0);
  EXPECT_NE(compare(Value::integer(1), Value::text("1")), 0);
}

TEST(Value, TextIsBytewiseAndCaseSensitive) {
  EXPECT_LT(compare(Value::text("B"), Value::text("a")), 0);
  EXPECT_LT(compare(Value::text("a"), Value::text("ab")), 0);
  EXPECT_LT(compare(Value::text("z"), Value::text("\xC3\xA9")), 0);
}

TEST(Value, RealComparesNumericallyWithInteger) {
  EXPECT_EQ(compare(Value::real_from_hundredths(200), Value::integer(2)), 0);
  EXPECT_LT(compare(Value::real_from_hundredths(199), Value::integer(2)), 0);
  EXPECT_GT(compare(Value::real_from_hundredths(-50), Value::integer(-1)), 0);
}

TEST(Value, Formatting) {
  EXPECT_EQ(to_string(Value::null()), "NULL");
  EXPECT_EQ(to_string(Value::integer(-42)), "-42");
  EXPECT_EQ(to_string(Value::text("hi")), "hi");
  EXPECT_EQ(to_string(Value::real_from_hundredths(450)), "4.50");
  EXPECT_EQ(to_string(Value::real_from_hundredths(-113)), "-1.13");
  EXPECT_EQ(to_string(Value::real_from_hundredths(0)), "0.00");
  EXPECT_EQ(to_string(Value::real_from_hundredths(-5)), "-0.05");
}
