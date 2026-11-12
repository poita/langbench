#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "rrule/rrule.hpp"

using namespace rrule;

namespace {

std::vector<std::string> run(const std::string& dtstart, const std::string& rule,
                             std::size_t n = 100000) {
  std::vector<std::string> out;
  for (const auto& t : expand(parse_datetime(dtstart), parse_rule(rule), n))
    out.push_back(format_datetime(t));
  return out;
}

using V = std::vector<std::string>;

}  // namespace

TEST(Expand, SpecExamples) {
  EXPECT_EQ(run("19970902T090000", "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=10"),
            (V{"19970926T090000", "19971128T090000", "19980130T090000",
               "19980327T090000", "19980529T090000", "19980731T090000",
               "19980925T090000", "19981127T090000", "19990129T090000",
               "19990326T090000"}));
  EXPECT_EQ(run("19970902T090000",
                "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,TH;COUNT=8"),
            (V{"19970902T090000", "19970904T090000", "19970916T090000",
               "19970918T090000", "19970930T090000", "19971002T090000",
               "19971014T090000", "19971016T090000"}));
  EXPECT_EQ(run("19970902T090000",
                "FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4", 4),
            (V{"19970902T090000", "19970907T090000", "19970916T090000",
               "19970921T090000"}));
}

TEST(Expand, DefaultsAndMonthEnds) {
  EXPECT_EQ(run("20240229T120000", "FREQ=YEARLY;COUNT=3"),
            (V{"20240229T120000", "20280229T120000", "20320229T120000"}));
  EXPECT_EQ(run("20240131T000000", "FREQ=MONTHLY;BYMONTHDAY=-1;UNTIL=20240430T000000"),
            (V{"20240131T000000", "20240229T000000", "20240331T000000",
               "20240430T000000"}));
  EXPECT_EQ(run("20260101T000000", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5"),
            V{});
}

TEST(Expand, SetPos) {
  EXPECT_EQ(run("20240301T080000",
                "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3"),
            (V{"20240329T080000", "20240430T080000", "20240531T080000"}));
  // Selected before the DTSTART check: first Monday of the start month is dropped.
  EXPECT_EQ(run("20240320T000000", "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;COUNT=2"),
            (V{"20240401T000000", "20240506T000000"}));
  // Duplicate positions select a day once.
  EXPECT_EQ(run("20240101T000000", "FREQ=MONTHLY;BYMONTHDAY=5;BYSETPOS=1,-1;COUNT=2"),
            (V{"20240105T000000", "20240205T000000"}));
}

TEST(Expand, WeekNumbers) {
  EXPECT_EQ(run("20200101T000000", "FREQ=YEARLY;BYWEEKNO=53;BYDAY=MO;COUNT=3"),
            (V{"20201228T000000", "20261228T000000", "20321227T000000"}));
  EXPECT_EQ(run("20110101T000000", "FREQ=YEARLY;BYWEEKNO=53;COUNT=4"),
            (V{"20110101T000000", "20110102T000000", "20151228T000000",
               "20151229T000000"}));
}

TEST(Expand, YearlyOrdinalsWithBymonth) {
  EXPECT_EQ(run("20240101T000000", "FREQ=YEARLY;BYMONTH=1,7;BYDAY=2MO;COUNT=4"),
            (V{"20240108T000000", "20240708T000000", "20250113T000000",
               "20250714T000000"}));
}

TEST(Expand, YearlyOrdinalsWholeYear) {
  // A 53rd Friday exists only in years starting on a Friday (or leap years starting on a Thursday).
  EXPECT_EQ(run("20200101T000000", "FREQ=YEARLY;BYDAY=53FR;COUNT=2"),
            (V{"20211231T000000", "20271231T000000"}));
  EXPECT_EQ(run("20200101T000000", "FREQ=YEARLY;BYDAY=-1MO;COUNT=2"),
            (V{"20201228T000000", "20211227T000000"}));
}

TEST(Expand, YearDays) {
  EXPECT_EQ(run("20240101T000000", "FREQ=YEARLY;BYYEARDAY=1,-1;COUNT=4"),
            (V{"20240101T000000", "20241231T000000", "20250101T000000",
               "20251231T000000"}));
}

TEST(Expand, UntilAndLimits) {
  EXPECT_EQ(run("20240101T120000", "FREQ=DAILY;UNTIL=20240103T120000"),
            (V{"20240101T120000", "20240102T120000", "20240103T120000"}));
  EXPECT_EQ(run("20240101T120000", "FREQ=DAILY;UNTIL=20240103T115959"),
            (V{"20240101T120000", "20240102T120000"}));
  EXPECT_EQ(run("20240101T120000", "FREQ=DAILY;UNTIL=20231231T000000"), V{});
  EXPECT_EQ(run("20240101T120000", "FREQ=DAILY;COUNT=10", 2).size(), 2u);
  EXPECT_EQ(run("20240101T120000", "FREQ=DAILY;COUNT=2", 10).size(), 2u);
}

TEST(Expand, StopsAtYear9999) {
  const V r = run("99990101T000000", "FREQ=MONTHLY;BYMONTHDAY=31");
  EXPECT_EQ(r, (V{"99990131T000000", "99990331T000000", "99990531T000000",
                  "99990731T000000", "99990831T000000", "99991031T000000",
                  "99991231T000000"}));
  EXPECT_EQ(run("99991230T000000", "FREQ=DAILY"),
            (V{"99991230T000000", "99991231T000000"}));
  // A never-matching WEEKLY rule steps past 9999 without failing.
  EXPECT_EQ(run("99990101T000000", "FREQ=WEEKLY;BYMONTH=2;BYMONTHDAY=30;COUNT=2"),
            V{});
}

TEST(Expand, WeeklyWkstPeriodZero) {
  // DTSTART on a WKST day: period 0 is the full 7 days.
  EXPECT_EQ(run("20240101T000000", "FREQ=WEEKLY;BYDAY=MO,SU;COUNT=3"),
            (V{"20240101T000000", "20240107T000000", "20240108T000000"}));
}
