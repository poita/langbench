#include "rrule/date.hpp"

#include <cstdio>

namespace rrule {

std::int64_t days_from_civil(int year, int month, int day) {
  static constexpr int kCumulative[12] = {0,   31,  59,  90,  120, 151,
                                          181, 212, 243, 273, 304, 334};
  const std::int64_t y = static_cast<std::int64_t>(year) - 1;
  std::int64_t n = 365 * y + y / 4 - y / 100 + y / 400;
  n += kCumulative[month - 1];
  if (month > 2 && is_leap_year(year)) ++n;
  return n + (day - 1);
}

Date civil_from_days(std::int64_t day_number) {
  // Work on a March-based year so that the leap day is the last day of the
  // year, which makes the 400-year cycle arithmetic regular. 0000-03-01 is
  // day number -306 relative to 0001-01-01; shift so that day 0 of the cycle
  // arithmetic is 0000-03-01.
  const std::int64_t z = day_number + 306;
  const std::int64_t era = z / 146097;
  const std::int64_t doe = z - era * 146097;                 // [0, 146096]
  const std::int64_t yoe =
      (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;  // [0, 399]
  const std::int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);  // [0, 365]
  const std::int64_t mp = (5 * doy + 2) / 153;                // [0, 11]
  Date d;
  d.day = static_cast<int>(doy - (153 * mp + 2) / 5 + 1);
  d.month = static_cast<int>(mp < 10 ? mp + 3 : mp - 9);
  d.year = static_cast<int>(yoe + era * 400 + (d.month <= 2 ? 1 : 0));
  return d;
}

Weekday weekday_of(const Date& d) { return weekday_of_day(days_from_civil(d)); }

std::int64_t to_seconds(const DateTime& t) {
  return days_from_civil(t.date) * kSecondsPerDay + seconds_of_day(t);
}

std::string format_datetime(const DateTime& t) {
  char buf[32];
  // Years beyond 9999 never appear in valid output; %04d keeps them readable.
  std::snprintf(buf, sizeof buf, "%04d%02d%02dT%02d%02d%02d", t.date.year,
                t.date.month, t.date.day, t.hour, t.minute, t.second);
  return buf;
}

}  // namespace rrule
