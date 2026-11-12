#include <gtest/gtest.h>

#include "rrule/date.hpp"

using namespace rrule;

TEST(Date, LeapYears) {
  EXPECT_TRUE(is_leap_year(2000));
  EXPECT_TRUE(is_leap_year(2024));
  EXPECT_FALSE(is_leap_year(1900));
  EXPECT_FALSE(is_leap_year(2023));
  EXPECT_TRUE(is_leap_year(1200));
}

TEST(Date, MonthLengths) {
  EXPECT_EQ(days_in_month(2024, 2), 29);
  EXPECT_EQ(days_in_month(2023, 2), 28);
  EXPECT_EQ(days_in_month(2023, 4), 30);
  EXPECT_EQ(days_in_month(2023, 12), 31);
  EXPECT_EQ(days_in_year(2000), 366);
  EXPECT_EQ(days_in_year(2100), 365);
}

TEST(Date, Anchors) {
  EXPECT_EQ(days_from_civil(1, 1, 1), 0);
  EXPECT_EQ(weekday_of({1, 1, 1}), Weekday::Monday);
  EXPECT_EQ(weekday_of({2000, 1, 1}), Weekday::Saturday);
  EXPECT_EQ(weekday_of({1997, 9, 2}), Weekday::Tuesday);
  EXPECT_EQ(weekday_of({2024, 2, 29}), Weekday::Thursday);
}

TEST(Date, RoundTripEveryDayFrom0001To10100) {
  std::int64_t expected = 0;
  for (int y = 1; y <= 10100; ++y) {
    for (int m = 1; m <= 12; ++m) {
      for (int d = 1; d <= days_in_month(y, m); ++d, ++expected) {
        ASSERT_EQ(days_from_civil(y, m, d), expected);
        const Date back = civil_from_days(expected);
        ASSERT_TRUE(back == (Date{y, m, d})) << y << "-" << m << "-" << d;
      }
    }
  }
}

TEST(Date, FormatDateTime) {
  DateTime t{{1000, 2, 3}, 4, 5, 6};
  EXPECT_EQ(format_datetime(t), "10000203T040506");
  EXPECT_LT(to_seconds(t), to_seconds(DateTime{{1000, 2, 3}, 4, 5, 7}));
}
