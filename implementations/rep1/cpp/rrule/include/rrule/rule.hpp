// The recurrence rule data model.
#pragma once

#include <optional>
#include <vector>

#include "rrule/date.hpp"

namespace rrule {

enum class Frequency { Yearly, Monthly, Weekly, Daily };

/// One BYDAY entry: a weekday, optionally with an ordinal (`2MO`, `-1FR`).
struct WeekdayRule {
  Weekday weekday = Weekday::Monday;
  int ordinal = 0;  ///< 0 means "no ordinal" (every such weekday)

  friend bool operator==(const WeekdayRule& a, const WeekdayRule& b) {
    return a.weekday == b.weekday && a.ordinal == b.ordinal;
  }
};

/// A parsed recurrence rule. Every `by_*` list is empty when the part is
/// absent. The struct holds exactly what was written; DTSTART-derived defaults
/// are added by `with_defaults`.
struct Rule {
  Frequency freq = Frequency::Daily;
  int interval = 1;
  std::optional<int> count;
  std::optional<DateTime> until;  ///< inclusive
  Weekday wkst = Weekday::Monday;

  std::vector<int> by_month;
  std::vector<int> by_month_day;
  std::vector<int> by_year_day;
  std::vector<int> by_week_no;
  std::vector<WeekdayRule> by_day;
  std::vector<int> by_set_pos;
};

/// Returns `rule` with the defaults derived from `dtstart` filled in: when none
/// of BYMONTHDAY, BYYEARDAY, BYWEEKNO and BYDAY is present, YEARLY gets
/// BYMONTH (if absent) and BYMONTHDAY, MONTHLY gets BYMONTHDAY and WEEKLY gets
/// BYDAY, all taken from `dtstart`.
Rule with_defaults(const Rule& rule, const DateTime& dtstart);

}  // namespace rrule
