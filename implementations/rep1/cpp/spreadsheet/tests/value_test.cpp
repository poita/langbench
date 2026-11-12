#include <gtest/gtest.h>

#include "spreadsheet/value.h"

using namespace spreadsheet;

TEST(FormatNumber, ZeroAndIntegers) {
  EXPECT_EQ(format_number(0.0), "0");
  EXPECT_EQ(format_number(-0.0), "0");
  EXPECT_EQ(format_number(42), "42");
  EXPECT_EQ(format_number(-7), "-7");
  EXPECT_EQ(format_number(123456789012345.0), "123456789012345");
  EXPECT_EQ(format_number(1e14), "100000000000000");
}

TEST(FormatNumber, LargeAndSmallUseScientific) {
  EXPECT_EQ(format_number(1e15), "1e+15");
  EXPECT_EQ(format_number(-1.5e15), "-1.5e+15");
  EXPECT_EQ(format_number(1e20), "1e+20");
  EXPECT_EQ(format_number(1.23456789e15), "1.23456789e+15");
  EXPECT_EQ(format_number(0.00001), "1e-05");
  EXPECT_EQ(format_number(2.5e-10), "2.5e-10");
}

TEST(FormatNumber, RoundsToTenSignificantDigits) {
  EXPECT_EQ(format_number(1.0 / 3), "0.3333333333");
  EXPECT_EQ(format_number(2.0 / 3), "0.6666666667");
  EXPECT_EQ(format_number(1234567.891), "1234567.891");
  EXPECT_EQ(format_number(0.0001234), "0.0001234");
  EXPECT_EQ(format_number(-2.5), "-2.5");
  EXPECT_EQ(format_number(1234567890.4), "1234567890");
  EXPECT_EQ(format_number(1234567890.5), "1234567890");  // tie to even
  EXPECT_EQ(format_number(2500000000.75), "2500000001");
  EXPECT_EQ(format_number(9999999999.7), "1e+10");
}

TEST(Value, KindsAndDisplay) {
  EXPECT_TRUE(Value().is_empty());
  EXPECT_EQ(Value().display(), "");
  EXPECT_EQ(Value::number(-0.0).display(), "0");
  EXPECT_EQ(Value::string("hi there").display(), "hi there");
  EXPECT_EQ(Value::error(ErrorCode::DivZero).display(), "#DIV/0!");
  EXPECT_EQ(Value::error(ErrorCode::Ref).display(), "#REF!");
  EXPECT_EQ(Value::error(ErrorCode::Cycle).display(), "#CYCLE!");
  EXPECT_EQ(Value::error(ErrorCode::Value).display(), "#VALUE!");
}

TEST(Value, Equality) {
  EXPECT_EQ(Value::number(1), Value::number(1));
  EXPECT_NE(Value::number(1), Value::string("1"));
  EXPECT_NE(Value::error(ErrorCode::Ref), Value::error(ErrorCode::Cycle));
  EXPECT_EQ(Value(), Value::empty());
}
