#include "mime/date.hpp"

#include <cstdio>
#include <vector>

#include "mime/text.hpp"

namespace mime {
namespace {

bool all_digits(std::string_view s) {
  if (s.empty()) return false;
  for (char c : s)
    if (c < '0' || c > '9') return false;
  return true;
}

int to_int(std::string_view s) {
  int v = 0;
  for (char c : s) v = v * 10 + (c - '0');
  return v;
}

bool is_leap(int y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }

int days_in_month(int y, int m) {
  static const int d[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  return m == 2 && is_leap(y) ? 29 : d[m - 1];
}

std::int64_t floor_div(std::int64_t a, std::int64_t b) {
  std::int64_t q = a / b;
  return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

// Parses 1-2 digit h:m[:s].
bool parse_time(std::string_view t, int& hh, int& mm, int& ss) {
  std::vector<std::string_view> parts;
  std::size_t start = 0;
  for (std::size_t i = 0; i <= t.size(); ++i) {
    if (i == t.size() || t[i] == ':') {
      parts.push_back(t.substr(start, i - start));
      start = i + 1;
    }
  }
  if (parts.size() != 2 && parts.size() != 3) return false;
  for (auto p : parts)
    if (!all_digits(p) || p.size() > 2) return false;
  hh = to_int(parts[0]);
  mm = to_int(parts[1]);
  ss = parts.size() == 3 ? to_int(parts[2]) : 0;
  return hh <= 23 && mm <= 59 && ss <= 60;
}

bool zone_offset(std::string_view z, int& minutes) {
  if (z.size() == 5 && (z[0] == '+' || z[0] == '-') && all_digits(z.substr(1))) {
    int v = to_int(z.substr(1, 2)) * 60 + to_int(z.substr(3, 2));
    minutes = z[0] == '-' ? -v : v;
    return true;
  }
  struct Zone { const char* name; int minutes; };
  static const Zone zones[] = {{"ut", 0},    {"gmt", 0},    {"z", 0},      {"est", -300},
                               {"edt", -240}, {"cst", -360}, {"cdt", -300}, {"mst", -420},
                               {"mdt", -360}, {"pst", -480}, {"pdt", -420}};
  std::string lower = ascii_lower(z);
  for (const Zone& zone : zones) {
    if (lower == zone.name) {
      minutes = zone.minutes;
      return true;
    }
  }
  return false;
}

}  // namespace

std::int64_t days_from_civil(std::int64_t y, unsigned m, unsigned d) {
  y -= m <= 2;
  const std::int64_t era = floor_div(y, 400);
  const std::int64_t yoe = y - era * 400;
  const std::int64_t doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
  const std::int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

void civil_from_days(std::int64_t z, std::int64_t& y, unsigned& m, unsigned& d) {
  z += 719468;
  const std::int64_t era = floor_div(z, 146097);
  const std::int64_t doe = z - era * 146097;
  const std::int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  y = yoe + era * 400;
  const std::int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  const std::int64_t mp = (5 * doy + 2) / 153;
  d = static_cast<unsigned>(doy - (153 * mp + 2) / 5 + 1);
  m = static_cast<unsigned>(mp < 10 ? mp + 3 : mp - 9);
  y += m <= 2;
}

std::optional<ParsedDate> parse_date(std::string_view raw) {
  // 1. Remove comments.
  std::string clean;
  for (std::size_t i = 0; i < raw.size();) {
    if (raw[i] == '(') i = skip_comment(raw, i);
    else clean += raw[i++];
  }
  // 2. Tokenise on blanks and commas.
  std::vector<std::string_view> toks;
  {
    std::string_view s = clean;
    std::size_t i = 0;
    while (i < s.size()) {
      while (i < s.size() && (is_blank(s[i]) || s[i] == ',')) ++i;
      std::size_t st = i;
      while (i < s.size() && !(is_blank(s[i]) || s[i] == ',')) ++i;
      if (i > st) toks.push_back(s.substr(st, i - st));
    }
  }
  // 3. Optional weekday.
  static const char* const weekdays[] = {"mon", "tue", "wed", "thu", "fri", "sat", "sun"};
  if (!toks.empty()) {
    std::string lower = ascii_lower(toks[0]);
    for (const char* w : weekdays) {
      if (lower == w) {
        toks.erase(toks.begin());
        break;
      }
    }
  }
  if (toks.size() < 4) return std::nullopt;

  // 4. Fields.
  if (!all_digits(toks[0]) || toks[0].size() > 2) return std::nullopt;
  int day = to_int(toks[0]);
  if (day < 1 || day > 31) return std::nullopt;

  static const char* const months[] = {"jan", "feb", "mar", "apr", "may", "jun",
                                       "jul", "aug", "sep", "oct", "nov", "dec"};
  int month = 0;
  {
    std::string lower = ascii_lower(toks[1]);
    for (int i = 0; i < 12; ++i)
      if (lower == months[i]) month = i + 1;
  }
  if (month == 0) return std::nullopt;

  if (!all_digits(toks[2]) || toks[2].size() < 2 || toks[2].size() > 4) return std::nullopt;
  int year = to_int(toks[2]);
  if (toks[2].size() == 2) year += year >= 50 ? 1900 : 2000;
  else if (toks[2].size() == 3) year += 1900;
  if (year < 1 || year > 9999) return std::nullopt;

  int hh, mm, ss;
  if (!parse_time(toks[3], hh, mm, ss)) return std::nullopt;

  int offset = 0;
  if (toks.size() > 4) {
    int minutes;
    if (zone_offset(toks[4], minutes)) offset = minutes;
  }

  // 5. Calendar validity.
  if (day > days_in_month(year, month)) return std::nullopt;

  std::int64_t epoch = days_from_civil(year, static_cast<unsigned>(month),
                                       static_cast<unsigned>(day)) * 86400 +
                       hh * 3600 + mm * 60 + ss - static_cast<std::int64_t>(offset) * 60;

  std::int64_t days = floor_div(epoch, 86400);
  std::int64_t tod = epoch - days * 86400;
  std::int64_t y;
  unsigned m, d;
  civil_from_days(days, y, m, d);

  ParsedDate out;
  out.epoch = epoch;
  out.offset_minutes = offset;
  char buf[64];
  std::snprintf(buf, sizeof buf, "%04lld-%02u-%02uT%02lld:%02lld:%02lldZ",
                static_cast<long long>(y), m, d, static_cast<long long>(tod / 3600),
                static_cast<long long>(tod / 60 % 60), static_cast<long long>(tod % 60));
  out.utc = buf;
  int abs_off = offset < 0 ? -offset : offset;
  std::snprintf(buf, sizeof buf, "%c%02d%02d", offset < 0 ? '-' : '+', abs_off / 60, abs_off % 60);
  out.offset = buf;
  return out;
}

}  // namespace mime
