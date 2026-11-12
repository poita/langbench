#include "rrule/rule.hpp"

namespace rrule {

Rule with_defaults(const Rule& rule, const DateTime& dtstart) {
  Rule r = rule;
  if (!r.by_month_day.empty() || !r.by_year_day.empty() ||
      !r.by_week_no.empty() || !r.by_day.empty()) {
    return r;
  }
  switch (r.freq) {
    case Frequency::Yearly:
      if (r.by_month.empty()) r.by_month.push_back(dtstart.date.month);
      r.by_month_day.push_back(dtstart.date.day);
      break;
    case Frequency::Monthly:
      r.by_month_day.push_back(dtstart.date.day);
      break;
    case Frequency::Weekly:
      r.by_day.push_back({weekday_of(dtstart.date), 0});
      break;
    case Frequency::Daily:
      break;
  }
  return r;
}

}  // namespace rrule
