#include "rrule/expander.hpp"

#include <algorithm>
#include <array>
#include <bitset>
#include <cstdint>

namespace rrule {
namespace {

using Day = std::int64_t;  // day number, see date.hpp

constexpr int kCumulativeDays[13] = {0,   0,   31,  59,  90,  120, 151,
                                     181, 212, 243, 273, 304, 334};

/// Index (1-based, within a range of `len` days whose first day has weekday
/// `first_wd`) of the `ordinal`-th `wd`, counted from the end when negative;
/// 0 when no such day exists.
int ordinal_index(int ordinal, int wd, int first_wd, int len) {
  int idx;
  if (ordinal > 0) {
    idx = 1 + (wd - first_wd + 7) % 7 + 7 * (ordinal - 1);
  } else {
    const int last_wd = (first_wd + len - 1) % 7;
    idx = len - (last_wd - wd + 7) % 7 - 7 * (-ordinal - 1);
  }
  return (idx >= 1 && idx <= len) ? idx : 0;
}

/// A rule compiled into constant-time membership tests.
struct Compiled {
  Frequency freq;
  int interval;
  int wkst;
  std::optional<int> count;

  bool has_month = false, has_month_day = false, has_year_day = false,
       has_week_no = false, has_plain_day = false, has_ordinal_day = false;
  std::uint16_t month_mask = 0;      // bit m = month m
  std::uint32_t md_pos = 0;          // bit d = month day d
  std::uint32_t md_neg = 0;          // bit d = month day -d
  std::bitset<367> yd_pos, yd_neg;   // bit d = year day +-d
  std::uint64_t wn_pos = 0, wn_neg = 0;  // bit w = week number +-w
  std::uint8_t day_mask = 0;         // bit wd = plain BYDAY weekday
  std::vector<WeekdayRule> ordinals;
  std::vector<int> set_pos;
};

Compiled compile(const Rule& r) {
  Compiled c;
  c.freq = r.freq;
  c.interval = r.interval;
  c.wkst = static_cast<int>(r.wkst);
  c.count = r.count;
  for (int m : r.by_month) c.month_mask |= static_cast<std::uint16_t>(1u << m);
  c.has_month = !r.by_month.empty();
  for (int v : r.by_month_day) {
    if (v > 0) c.md_pos |= 1u << v;
    else c.md_neg |= 1u << -v;
  }
  c.has_month_day = !r.by_month_day.empty();
  for (int v : r.by_year_day) {
    if (v > 0) c.yd_pos.set(v);
    else c.yd_neg.set(-v);
  }
  c.has_year_day = !r.by_year_day.empty();
  for (int v : r.by_week_no) {
    if (v > 0) c.wn_pos |= 1ull << v;
    else c.wn_neg |= 1ull << -v;
  }
  c.has_week_no = !r.by_week_no.empty();
  for (const auto& d : r.by_day) {
    if (d.ordinal == 0) {
      c.day_mask |= static_cast<std::uint8_t>(1u << static_cast<int>(d.weekday));
      c.has_plain_day = true;
    } else {
      c.ordinals.push_back(d);
      c.has_ordinal_day = true;
    }
  }
  c.set_pos = r.by_set_pos;
  return c;
}

/// Calendar position of one candidate day, advanced incrementally.
struct Cursor {
  Day dn;
  int year, month, day, yday;  // yday is 1-based
  int wd;
  int month_len, year_len;

  explicit Cursor(Day start) : dn(start) {
    const Date d = civil_from_days(start);
    year = d.year;
    month = d.month;
    day = d.day;
    yday = static_cast<int>(start - days_from_civil(year, 1, 1)) + 1;
    wd = static_cast<int>(start % 7);
    month_len = days_in_month(year, month);
    year_len = days_in_year(year);
  }

  void advance() {
    ++dn;
    wd = wd == 6 ? 0 : wd + 1;
    ++yday;
    if (++day > month_len) {
      day = 1;
      if (++month > 12) {
        month = 1;
        ++year;
        yday = 1;
        year_len = days_in_year(year);
      }
      month_len = days_in_month(year, month);
    }
  }
};

/// Per-period values that depend only on the year or month range (computed once
/// per period, so each candidate day stays O(1)).
struct PeriodContext {
  // BYWEEKNO (YEARLY): SPEC.md section 4.
  int week_start = 0;      // s(Y)
  int weeks = 0;           // weeks(Y)
  int prev_week_label = 0;  // P, the label of the days before week 1
  // Ordinal BYDAY: SPEC.md section 5.
  std::bitset<367> ord_year;                 // YEARLY without BYMONTH: by year day
  std::array<std::uint32_t, 13> ord_month{};  // MONTHLY / YEARLY+BYMONTH: by month day
};

int first_offset(int jan1_wd, int wkst) { return (wkst - jan1_wd + 7) % 7; }
int week1_start(int first) { return first < 4 ? first : first - 7; }
int week_count(int year_len, int s) {
  const int l = year_len - s;
  return l / 7 + (l % 7 >= 4 ? 1 : 0);
}

void setup_week_numbers(const Compiled& c, int year, PeriodContext& ctx) {
  const Day jan1 = days_from_civil(year, 1, 1);
  const int len = days_in_year(year);
  const int s = week1_start(first_offset(static_cast<int>(jan1 % 7), c.wkst));
  ctx.week_start = s;
  ctx.weeks = week_count(len, s);

  const int prev_len = days_in_year(year - 1);
  const int prev_jan1_wd = static_cast<int>((jan1 - prev_len) % 7);
  const int prev_s = week1_start(first_offset(prev_jan1_wd, c.wkst));
  if (prev_s < 0) {
    ctx.prev_week_label = week_count(prev_len, prev_s);
  } else {
    ctx.prev_week_label = 52 + ((len - s) % 7 >= 4 ? 1 : 0);
  }
}

void setup_ordinals_month(const Compiled& c, int year, int month, Day month_start,
                          PeriodContext& ctx) {
  const int len = days_in_month(year, month);
  const int first_wd = static_cast<int>(month_start % 7);
  std::uint32_t mask = 0;
  for (const auto& o : c.ordinals) {
    const int idx =
        ordinal_index(o.ordinal, static_cast<int>(o.weekday), first_wd, len);
    if (idx) mask |= 1u << idx;
  }
  ctx.ord_month[month] = mask;
}

void setup_ordinals_year(const Compiled& c, int year, Day jan1,
                         PeriodContext& ctx) {
  const int len = days_in_year(year);
  const int first_wd = static_cast<int>(jan1 % 7);
  ctx.ord_year.reset();
  for (const auto& o : c.ordinals) {
    const int idx =
        ordinal_index(o.ordinal, static_cast<int>(o.weekday), first_wd, len);
    if (idx) ctx.ord_year.set(idx);
  }
}

bool matches_week_number(const Compiled& c, const Cursor& cur,
                         const PeriodContext& ctx) {
  const int i = cur.yday - 1;
  const int s = ctx.week_start;
  if (i < s) {  // case (b)
    return ((c.wn_neg >> 1) & 1) || ((c.wn_pos >> ctx.prev_week_label) & 1);
  }
  const int w = (i - s) / 7 + 1;
  if (w <= ctx.weeks) {  // case (a)
    return ((c.wn_pos >> w) & 1) || ((c.wn_neg >> (ctx.weeks - w + 1)) & 1);
  }
  return (c.wn_pos >> 1) & 1;  // case (c)
}

bool day_matches(const Compiled& c, const Cursor& cur, const PeriodContext& ctx) {
  if (c.has_month && !((c.month_mask >> cur.month) & 1)) return false;
  if (c.has_week_no && !matches_week_number(c, cur, ctx)) return false;
  if (c.has_plain_day && !((c.day_mask >> cur.wd) & 1)) return false;
  if (c.has_ordinal_day) {
    const bool hit = (c.freq == Frequency::Yearly && !c.has_month)
                         ? ctx.ord_year.test(cur.yday)
                         : ((ctx.ord_month[cur.month] >> cur.day) & 1) != 0;
    if (!hit) return false;
  }
  if (c.has_month_day &&
      !(((c.md_pos >> cur.day) & 1) ||
        ((c.md_neg >> (cur.month_len - cur.day + 1)) & 1))) {
    return false;
  }
  if (c.has_year_day &&
      !(c.yd_pos.test(cur.yday) || c.yd_neg.test(cur.year_len - cur.yday + 1))) {
    return false;
  }
  return true;
}

}  // namespace

std::vector<DateTime> expand(const DateTime& dtstart, const Rule& input_rule,
                             std::size_t limit) {
  std::vector<DateTime> out;
  if (limit == 0) return out;
  const Rule rule = with_defaults(input_rule, dtstart);
  const Compiled c = compile(rule);

  const int tod = seconds_of_day(dtstart);
  const Day start_day = days_from_civil(dtstart.date);
  const std::int64_t start_key = start_day * kSecondsPerDay + tod;
  const bool has_until = rule.until.has_value();
  const std::int64_t until_key = has_until ? to_seconds(*rule.until) : 0;
  const Day last_day = days_from_civil(kMaxYear, 12, 31);

  const int wd0 = static_cast<int>(start_day % 7);
  const Day week_anchor = start_day - (wd0 - c.wkst + 7) % 7;  // "A" of SPEC §2

  const bool yearly_ordinal_by_year =
      c.has_ordinal_day && c.freq == Frequency::Yearly && !c.has_month;
  const bool yearly_ordinal_by_month =
      c.has_ordinal_day && c.freq == Frequency::Yearly && c.has_month;

  std::vector<Day> kept;
  std::vector<std::size_t> picks;
  std::size_t printed = 0;
  PeriodContext ctx;

  for (std::int64_t k = 0;; ++k) {
    // --- the period: first day and number of days -------------------------
    Day first;
    int len;
    int year_of_period = 0;  // only meaningful for YEARLY
    switch (c.freq) {
      case Frequency::Yearly: {
        const std::int64_t y = dtstart.date.year + k * c.interval;
        if (y > kMaxYear) return out;
        year_of_period = static_cast<int>(y);
        first = days_from_civil(year_of_period, 1, 1);
        len = days_in_year(year_of_period);
        break;
      }
      case Frequency::Monthly: {
        const std::int64_t months = (dtstart.date.month - 1) + k * c.interval;
        const std::int64_t y = dtstart.date.year + months / 12;
        if (y > kMaxYear) return out;
        const int m = static_cast<int>(months % 12) + 1;
        first = days_from_civil(static_cast<int>(y), m, 1);
        len = days_in_month(static_cast<int>(y), m);
        break;
      }
      case Frequency::Weekly:
        if (k == 0) {
          first = start_day;
          len = 7 - (wd0 - c.wkst + 7) % 7;
        } else {
          first = week_anchor + 7 * k * c.interval;
          len = 7;
        }
        if (first > last_day) return out;
        break;
      case Frequency::Daily:
        first = start_day + k * c.interval;
        len = 1;
        if (first > last_day) return out;
        break;
    }
    if (has_until && first * kSecondsPerDay + tod > until_key) return out;

    Cursor cur(first);

    // --- per-period setup -------------------------------------------------
    if (c.has_week_no) setup_week_numbers(c, cur.year, ctx);
    if (c.has_ordinal_day) {
      if (yearly_ordinal_by_year) {
        setup_ordinals_year(c, cur.year, first, ctx);
      } else if (yearly_ordinal_by_month) {
        ctx.ord_month.fill(0);
        for (int m = 1; m <= 12; ++m) {
          if (!((c.month_mask >> m) & 1)) continue;
          const Day ms = first + kCumulativeDays[m] +
                         (m > 2 && is_leap_year(year_of_period) ? 1 : 0);
          setup_ordinals_month(c, year_of_period, m, ms, ctx);
        }
      } else {  // MONTHLY
        setup_ordinals_month(c, cur.year, cur.month, first, ctx);
      }
    }

    // --- filter the candidate days ----------------------------------------
    kept.clear();
    for (int i = 0; i < len; ++i, cur.advance()) {
      if (day_matches(c, cur, ctx)) kept.push_back(cur.dn);
    }

    // --- BYSETPOS ----------------------------------------------------------
    if (!c.set_pos.empty()) {
      const std::int64_t n = static_cast<std::int64_t>(kept.size());
      picks.clear();
      for (int p : c.set_pos) {
        const std::int64_t idx = p > 0 ? p - 1 : n + p;
        if (idx >= 0 && idx < n) picks.push_back(static_cast<std::size_t>(idx));
      }
      std::sort(picks.begin(), picks.end());
      picks.erase(std::unique(picks.begin(), picks.end()), picks.end());
      std::size_t w = 0;
      for (std::size_t idx : picks) kept[w++] = kept[idx];
      kept.resize(w);
    }

    // --- emit --------------------------------------------------------------
    for (Day d : kept) {
      const std::int64_t key = d * kSecondsPerDay + tod;
      if (has_until && key > until_key) return out;
      if (key < start_key) continue;
      DateTime t = dtstart;
      t.date = civil_from_days(d);
      out.push_back(t);
      ++printed;
      if (c.count && printed >= static_cast<std::size_t>(*c.count)) return out;
      if (printed >= limit) return out;
    }
  }
}

}  // namespace rrule
