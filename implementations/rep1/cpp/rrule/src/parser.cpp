#include "rrule/parser.hpp"

#include <cstdint>
#include <utility>

namespace rrule {
namespace {

[[noreturn]] void fail(const std::string& what, std::string_view text) {
  throw ParseError(what + ": '" + std::string(text) + "'");
}

int parse_int(std::string_view s, int lo, int hi, const char* what) {
  if (s.empty()) fail(std::string("empty ") + what, s);
  std::size_t i = 0;
  bool neg = false;
  if (s[0] == '-') {
    neg = true;
    i = 1;
  }
  if (i == s.size()) fail(std::string("bad ") + what, s);
  std::int64_t v = 0;
  for (; i < s.size(); ++i) {
    if (s[i] < '0' || s[i] > '9') fail(std::string("bad ") + what, s);
    v = v * 10 + (s[i] - '0');
    if (v > 1000000000) fail(std::string("out of range ") + what, s);
  }
  if (neg) v = -v;
  if (v < lo || v > hi) fail(std::string("out of range ") + what, s);
  return static_cast<int>(v);
}

int digits(std::string_view s, std::size_t pos, std::size_t n) {
  int v = 0;
  for (std::size_t i = pos; i < pos + n; ++i) {
    if (s[i] < '0' || s[i] > '9') fail("bad date-time", s);
    v = v * 10 + (s[i] - '0');
  }
  return v;
}

bool parse_weekday_code(std::string_view s, Weekday& out) {
  static constexpr std::pair<const char*, Weekday> kCodes[] = {
      {"MO", Weekday::Monday},   {"TU", Weekday::Tuesday},
      {"WE", Weekday::Wednesday}, {"TH", Weekday::Thursday},
      {"FR", Weekday::Friday},   {"SA", Weekday::Saturday},
      {"SU", Weekday::Sunday}};
  for (const auto& [code, wd] : kCodes) {
    if (s == code) {
      out = wd;
      return true;
    }
  }
  return false;
}

template <typename F>
void for_each_item(std::string_view list, F&& f) {
  std::size_t start = 0;
  while (true) {
    const std::size_t comma = list.find(',', start);
    const std::string_view item = list.substr(
        start, comma == std::string_view::npos ? comma : comma - start);
    f(item);
    if (comma == std::string_view::npos) break;
    start = comma + 1;
  }
}

std::vector<int> parse_int_list(std::string_view s, int lo, int hi,
                                const char* what) {
  std::vector<int> out;
  for_each_item(s, [&](std::string_view item) {
    const int v = parse_int(item, -hi, hi, what);
    if (v == 0 || v < lo) fail(std::string("out of range ") + what, item);
    out.push_back(v);
  });
  return out;
}

// For lists that are positive only (BYMONTH).
std::vector<int> parse_positive_list(std::string_view s, int lo, int hi,
                                     const char* what) {
  std::vector<int> out;
  for_each_item(s, [&](std::string_view item) {
    out.push_back(parse_int(item, lo, hi, what));
  });
  return out;
}

std::vector<WeekdayRule> parse_byday(std::string_view s) {
  std::vector<WeekdayRule> out;
  for_each_item(s, [&](std::string_view item) {
    if (item.size() < 2) fail("bad BYDAY entry", item);
    WeekdayRule r;
    if (!parse_weekday_code(item.substr(item.size() - 2), r.weekday))
      fail("bad BYDAY weekday", item);
    const std::string_view prefix = item.substr(0, item.size() - 2);
    if (!prefix.empty()) {
      r.ordinal = parse_int(prefix, -53, 53, "BYDAY ordinal");
      if (r.ordinal == 0) fail("bad BYDAY ordinal", item);
    }
    out.push_back(r);
  });
  return out;
}

}  // namespace

DateTime parse_datetime(std::string_view text) {
  if (text.size() != 15 || text[8] != 'T') fail("bad date-time", text);
  DateTime t;
  t.date.year = digits(text, 0, 4);
  t.date.month = digits(text, 4, 2);
  t.date.day = digits(text, 6, 2);
  t.hour = digits(text, 9, 2);
  t.minute = digits(text, 11, 2);
  t.second = digits(text, 13, 2);
  if (t.date.year < 1 || t.date.month < 1 || t.date.month > 12 ||
      t.date.day < 1 ||
      t.date.day > days_in_month(t.date.year, t.date.month) || t.hour > 23 ||
      t.minute > 59 || t.second > 59) {
    fail("date-time out of range", text);
  }
  return t;
}

Rule parse_rule(std::string_view text) {
  Rule rule;
  bool have_freq = false;
  std::size_t start = 0;
  while (start <= text.size()) {
    const std::size_t semi = text.find(';', start);
    const std::string_view part = text.substr(
        start, semi == std::string_view::npos ? semi : semi - start);
    const std::size_t eq = part.find('=');
    if (eq == std::string_view::npos) fail("bad rule part", part);
    const std::string_view name = part.substr(0, eq);
    const std::string_view value = part.substr(eq + 1);

    if (name == "FREQ") {
      have_freq = true;
      if (value == "YEARLY") rule.freq = Frequency::Yearly;
      else if (value == "MONTHLY") rule.freq = Frequency::Monthly;
      else if (value == "WEEKLY") rule.freq = Frequency::Weekly;
      else if (value == "DAILY") rule.freq = Frequency::Daily;
      else fail("unsupported FREQ", value);
    } else if (name == "INTERVAL") {
      rule.interval = parse_int(value, 1, 1000000, "INTERVAL");
    } else if (name == "COUNT") {
      rule.count = parse_int(value, 1, 1000000000, "COUNT");
    } else if (name == "UNTIL") {
      rule.until = parse_datetime(value);
    } else if (name == "WKST") {
      if (!parse_weekday_code(value, rule.wkst)) fail("bad WKST", value);
    } else if (name == "BYMONTH") {
      rule.by_month = parse_positive_list(value, 1, 12, "BYMONTH");
    } else if (name == "BYMONTHDAY") {
      rule.by_month_day = parse_int_list(value, -31, 31, "BYMONTHDAY");
    } else if (name == "BYYEARDAY") {
      rule.by_year_day = parse_int_list(value, -366, 366, "BYYEARDAY");
    } else if (name == "BYWEEKNO") {
      rule.by_week_no = parse_int_list(value, -53, 53, "BYWEEKNO");
    } else if (name == "BYDAY") {
      rule.by_day = parse_byday(value);
    } else if (name == "BYSETPOS") {
      rule.by_set_pos = parse_int_list(value, -366, 366, "BYSETPOS");
    } else {
      fail("unknown rule part", name);
    }

    if (semi == std::string_view::npos) break;
    start = semi + 1;
  }
  if (!have_freq) fail("missing FREQ", text);
  return rule;
}

}  // namespace rrule
