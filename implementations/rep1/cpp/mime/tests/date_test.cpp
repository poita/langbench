#include <gtest/gtest.h>

#include "mime/date.hpp"

using namespace mime;

namespace {
void expect_date(const char* raw, std::int64_t epoch, const char* utc, const char* offset) {
  auto d = parse_date(raw);
  ASSERT_TRUE(d) << raw;
  EXPECT_EQ(d->epoch, epoch) << raw;
  EXPECT_EQ(d->utc, utc) << raw;
  EXPECT_EQ(d->offset, offset) << raw;
}
}  // namespace

TEST(Date, SpecExamples) {
  expect_date("Sun, 29 Feb 2004 22:03:22 -0800", 1078121002, "2004-03-01T06:03:22Z", "-0800");
  expect_date("3 Jan 70 00:00:00 GMT", 172800, "1970-01-03T00:00:00Z", "+0000");
  expect_date("Tue, 1 Jan 2036 00:00:60 +0000", 2082758460, "2036-01-01T00:01:00Z", "+0000");
  expect_date("Mon, 3 Mar 1969 12:00 (GMT) -0500", -26204400, "1969-03-03T17:00:00Z", "-0500");
  expect_date("Sun, 07 Mar 2004 15:21:26 -0000", 1078672886, "2004-03-07T15:21:26Z", "+0000");
  expect_date("1 Jan 2000 00:00:00 +2359", 946598460, "1999-12-31T00:01:00Z", "+2359");
  EXPECT_FALSE(parse_date("not a date"));
}

TEST(Date, ZonesAndOddities) {
  expect_date("1 Jan 2000 00:00:00 EST", 946684800 + 18000, "2000-01-01T05:00:00Z", "-0500");
  expect_date("1 Jan 2000 00:00:00 bogus", 946684800, "2000-01-01T00:00:00Z", "+0000");
  expect_date("1 Jan 2000 00:00", 946684800, "2000-01-01T00:00:00Z", "+0000");
  expect_date("1 Jan 2000 00:00:00 +9999", 946684800 - 6039 * 60, "1999-12-27T19:21:00Z", "+10039");
  expect_date("1 jan 123 0:0:0", 1672531200, "2023-01-01T00:00:00Z", "+0000");
}

TEST(Date, Invalid) {
  EXPECT_FALSE(parse_date("31 Apr 2000 00:00:00"));
  EXPECT_FALSE(parse_date("29 Feb 2001 00:00:00"));
  EXPECT_TRUE(parse_date("29 Feb 2000 00:00:00"));
  EXPECT_FALSE(parse_date("29 Feb 1900 00:00:00"));
  EXPECT_FALSE(parse_date("1 Jan 2000 24:00:00"));
  EXPECT_FALSE(parse_date("1 Jan 2000 00:60:00"));
  EXPECT_FALSE(parse_date("1 Jan 2000 00:00:61"));
  EXPECT_FALSE(parse_date("1 Jan 0000 00:00:00"));
  EXPECT_FALSE(parse_date("1 Jan 2000"));
  EXPECT_FALSE(parse_date("0 Jan 2000 00:00:00"));
  EXPECT_FALSE(parse_date("1 Janu 2000 00:00:00"));
}

TEST(Date, CivilRoundTrip) {
  EXPECT_EQ(days_from_civil(1970, 1, 1), 0);
  EXPECT_EQ(days_from_civil(1969, 12, 31), -1);
  for (std::int64_t z = -800000; z < 3000000; z += 997) {
    std::int64_t y;
    unsigned m, d;
    civil_from_days(z, y, m, d);
    EXPECT_EQ(days_from_civil(y, m, d), z);
  }
}
