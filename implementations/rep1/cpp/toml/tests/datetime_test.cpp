#include <gtest/gtest.h>

#include "toml/datetime.hpp"

using toml::scan_datetime;
using toml::Type;

namespace {
void expect_ok(std::string_view in, Type type, std::string_view canon) {
  auto r = scan_datetime(in);
  ASSERT_TRUE(r) << in;
  EXPECT_EQ(r->type, type) << in;
  EXPECT_EQ(r->text, canon) << in;
  EXPECT_EQ(r->length, in.size()) << in;
}
}  // namespace

TEST(DateTime, Kinds) {
  expect_ok("1979-05-27", Type::DateLocal, "1979-05-27");
  expect_ok("07:32:00", Type::TimeLocal, "07:32:00");
  expect_ok("1979-05-27T07:32:00", Type::DateTimeLocal, "1979-05-27T07:32:00");
  expect_ok("1979-05-27T07:32:00Z", Type::DateTime, "1979-05-27T07:32:00Z");
  expect_ok("1979-05-27T00:32:00-07:00", Type::DateTime, "1979-05-27T00:32:00-07:00");
}

TEST(DateTime, Canonicalisation) {
  expect_ok("1987-07-05 17:45:00z", Type::DateTime, "1987-07-05T17:45:00Z");
  expect_ok("1987-07-05t17:45:00", Type::DateTimeLocal, "1987-07-05T17:45:00");
  expect_ok("1987-07-05T17:45:56.600+08:00", Type::DateTime, "1987-07-05T17:45:56.6+08:00");
  expect_ok("1979-05-27t07:32:00-00:00", Type::DateTime, "1979-05-27T07:32:00Z");
  expect_ok("1979-05-27T07:32:00+00:00", Type::DateTime, "1979-05-27T07:32:00Z");
  expect_ok("07:32:00.000", Type::TimeLocal, "07:32:00");
  expect_ok("07:32:00.5", Type::TimeLocal, "07:32:00.5");
  expect_ok("07:32:00.123456789012", Type::TimeLocal, "07:32:00.123456789012");
}

TEST(DateTime, StopsAtTheEndOfTheLiteral) {
  auto r = scan_datetime("1979-05-27 # comment");
  ASSERT_TRUE(r);
  EXPECT_EQ(r->type, Type::DateLocal);
  EXPECT_EQ(r->length, 10u);
  r = scan_datetime("1979-05-27, 2");
  ASSERT_TRUE(r);
  EXPECT_EQ(r->length, 10u);
}

TEST(DateTime, CalendarValidation) {
  EXPECT_TRUE(scan_datetime("2024-02-29"));
  EXPECT_FALSE(scan_datetime("2023-02-29"));
  EXPECT_FALSE(scan_datetime("1900-02-29"));
  EXPECT_TRUE(scan_datetime("2000-02-29"));
  EXPECT_FALSE(scan_datetime("2023-04-31"));
  EXPECT_FALSE(scan_datetime("2023-13-01"));
  EXPECT_FALSE(scan_datetime("2023-00-10"));
  EXPECT_FALSE(scan_datetime("2023-01-00"));
  EXPECT_FALSE(scan_datetime("0000-01-01"));
}

TEST(DateTime, TimeValidation) {
  EXPECT_TRUE(scan_datetime("23:59:59"));
  EXPECT_FALSE(scan_datetime("24:00:00"));
  EXPECT_FALSE(scan_datetime("12:60:00"));
  EXPECT_FALSE(scan_datetime("12:00:60"));  // no leap seconds
  EXPECT_FALSE(scan_datetime("12:00"));     // seconds are mandatory
  EXPECT_FALSE(scan_datetime("12:00:00."));
}

TEST(DateTime, RejectsBadShapes) {
  EXPECT_FALSE(scan_datetime("1987-7-05"));
  EXPECT_FALSE(scan_datetime("987-07-05"));
  EXPECT_FALSE(scan_datetime("1987-07-05T"));
  EXPECT_FALSE(scan_datetime("1987-07-05T17:45"));
  EXPECT_FALSE(scan_datetime("1987-07-05 17:45"));
  EXPECT_FALSE(scan_datetime("\xD9\xA1\xD9\xA9\xD9\xA8\xD9\xA7-01-01"));  // Arabic-Indic digits
  EXPECT_FALSE(scan_datetime("abcd-ef-gh"));
}

TEST(DateTime, OffsetValidation) {
  // An invalid offset is not consumed, so the caller sees leftover input.
  auto r = scan_datetime("1979-05-27T07:32:00+24:00");
  ASSERT_TRUE(r);
  EXPECT_EQ(r->type, Type::DateTimeLocal);
  EXPECT_LT(r->length, 25u);
}
