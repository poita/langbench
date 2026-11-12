#include <gtest/gtest.h>

#include "rrule/parser.hpp"

using namespace rrule;

TEST(ParseDateTime, Valid) {
  const DateTime t = parse_datetime("19970902T090000");
  EXPECT_TRUE(t == (DateTime{{1997, 9, 2}, 9, 0, 0}));
}

TEST(ParseDateTime, Invalid) {
  EXPECT_THROW(parse_datetime("19970902"), ParseError);
  EXPECT_THROW(parse_datetime("19970230T000000"), ParseError);
  EXPECT_THROW(parse_datetime("19970902T240000"), ParseError);
  EXPECT_THROW(parse_datetime("1997090xT000000"), ParseError);
}

TEST(ParseRule, AllParts) {
  const Rule r = parse_rule(
      "FREQ=YEARLY;INTERVAL=3;UNTIL=20300101T000000;WKST=SU;BYMONTH=1,12;"
      "BYMONTHDAY=1,-1;BYYEARDAY=-366,100;BYWEEKNO=53,-1;BYDAY=2MO,-1FR;"
      "BYSETPOS=-1,2");
  EXPECT_EQ(r.freq, Frequency::Yearly);
  EXPECT_EQ(r.interval, 3);
  EXPECT_FALSE(r.count.has_value());
  ASSERT_TRUE(r.until.has_value());
  EXPECT_EQ(r.until->date.year, 2030);
  EXPECT_EQ(r.wkst, Weekday::Sunday);
  EXPECT_EQ(r.by_month, (std::vector<int>{1, 12}));
  EXPECT_EQ(r.by_month_day, (std::vector<int>{1, -1}));
  EXPECT_EQ(r.by_year_day, (std::vector<int>{-366, 100}));
  EXPECT_EQ(r.by_week_no, (std::vector<int>{53, -1}));
  ASSERT_EQ(r.by_day.size(), 2u);
  EXPECT_TRUE((r.by_day[0] == WeekdayRule{Weekday::Monday, 2}));
  EXPECT_TRUE((r.by_day[1] == WeekdayRule{Weekday::Friday, -1}));
  EXPECT_EQ(r.by_set_pos, (std::vector<int>{-1, 2}));
}

TEST(ParseRule, CountAndPlainByDay) {
  const Rule r = parse_rule("BYDAY=MO,SU;COUNT=5;FREQ=WEEKLY");
  EXPECT_EQ(r.freq, Frequency::Weekly);
  EXPECT_EQ(r.count, 5);
  EXPECT_EQ(r.by_day[0].ordinal, 0);
  EXPECT_EQ(r.by_day[1].weekday, Weekday::Sunday);
}

TEST(ParseRule, Errors) {
  EXPECT_THROW(parse_rule("COUNT=3"), ParseError);
  EXPECT_THROW(parse_rule("FREQ=HOURLY"), ParseError);
  EXPECT_THROW(parse_rule("FREQ=DAILY;BYFOO=1"), ParseError);
  EXPECT_THROW(parse_rule("FREQ=DAILY;BYMONTH=13"), ParseError);
  EXPECT_THROW(parse_rule("FREQ=DAILY;BYMONTHDAY=0"), ParseError);
  EXPECT_THROW(parse_rule("FREQ=DAILY;BYDAY=XX"), ParseError);
  EXPECT_THROW(parse_rule("FREQ=DAILY;"), ParseError);
}

TEST(Defaults, FromDtstart) {
  const DateTime dt = parse_datetime("20240229T120000");  // a Thursday
  Rule y = with_defaults(parse_rule("FREQ=YEARLY"), dt);
  EXPECT_EQ(y.by_month, std::vector<int>{2});
  EXPECT_EQ(y.by_month_day, std::vector<int>{29});
  Rule m = with_defaults(parse_rule("FREQ=MONTHLY"), dt);
  EXPECT_EQ(m.by_month_day, std::vector<int>{29});
  Rule w = with_defaults(parse_rule("FREQ=WEEKLY"), dt);
  ASSERT_EQ(w.by_day.size(), 1u);
  EXPECT_EQ(w.by_day[0].weekday, Weekday::Thursday);
  Rule d = with_defaults(parse_rule("FREQ=DAILY"), dt);
  EXPECT_TRUE(d.by_month_day.empty() && d.by_day.empty());
  // No defaults when a BY part that suppresses them is present.
  Rule s = with_defaults(parse_rule("FREQ=YEARLY;BYDAY=MO"), dt);
  EXPECT_TRUE(s.by_month.empty() && s.by_month_day.empty());
}
