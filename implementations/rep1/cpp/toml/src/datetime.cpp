#include "toml/datetime.hpp"

namespace toml {

namespace {

bool is_digit(char c) { return c >= '0' && c <= '9'; }

bool digits_at(std::string_view s, std::size_t pos, std::size_t count) {
  if (pos + count > s.size()) return false;
  for (std::size_t k = 0; k < count; ++k)
    if (!is_digit(s[pos + k])) return false;
  return true;
}

int num(std::string_view s, std::size_t pos, std::size_t count) {
  int v = 0;
  for (std::size_t k = 0; k < count; ++k) v = v * 10 + (s[pos + k] - '0');
  return v;
}

bool is_leap(int y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }

int days_in_month(int y, int m) {
  static const int days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  return (m == 2 && is_leap(y)) ? 29 : days[m - 1];
}

// YYYY-MM-DD at `pos`; appends it to `out` and advances `pos` on success.
bool scan_date(std::string_view s, std::size_t& pos, std::string& out) {
  if (!digits_at(s, pos, 4) || pos + 4 >= s.size() || s[pos + 4] != '-' ||
      !digits_at(s, pos + 5, 2) || pos + 7 >= s.size() || s[pos + 7] != '-' ||
      !digits_at(s, pos + 8, 2))
    return false;
  int y = num(s, pos, 4), m = num(s, pos + 5, 2), d = num(s, pos + 8, 2);
  if (y < 1 || m < 1 || m > 12 || d < 1 || d > days_in_month(y, m)) return false;
  out.append(s.substr(pos, 10));
  pos += 10;
  return true;
}

// HH:MM:SS[.frac] at `pos`.
bool scan_time(std::string_view s, std::size_t& pos, std::string& out) {
  if (!digits_at(s, pos, 2) || pos + 2 >= s.size() || s[pos + 2] != ':' ||
      !digits_at(s, pos + 3, 2) || pos + 5 >= s.size() || s[pos + 5] != ':' ||
      !digits_at(s, pos + 6, 2))
    return false;
  if (num(s, pos, 2) > 23 || num(s, pos + 3, 2) > 59 || num(s, pos + 6, 2) > 59) return false;
  out.append(s.substr(pos, 8));
  pos += 8;
  if (pos < s.size() && s[pos] == '.') {
    std::size_t start = pos + 1, end = start;
    while (end < s.size() && is_digit(s[end])) ++end;
    if (end == start) return false;
    std::size_t keep = end;
    while (keep > start && s[keep - 1] == '0') --keep;
    if (keep > start) {
      out.push_back('.');
      out.append(s.substr(start, keep - start));
    }
    pos = end;
  }
  return true;
}

// Z | z | (+|-)HH:MM at `pos`.
bool scan_offset(std::string_view s, std::size_t& pos, std::string& out) {
  if (pos >= s.size()) return false;
  if (s[pos] == 'Z' || s[pos] == 'z') {
    out.push_back('Z');
    ++pos;
    return true;
  }
  if (s[pos] != '+' && s[pos] != '-') return false;
  if (!digits_at(s, pos + 1, 2) || pos + 3 >= s.size() || s[pos + 3] != ':' ||
      !digits_at(s, pos + 4, 2))
    return false;
  int h = num(s, pos + 1, 2), m = num(s, pos + 4, 2);
  if (h > 23 || m > 59) return false;
  if (h == 0 && m == 0)
    out.push_back('Z');
  else
    out.append(s.substr(pos, 6));
  pos += 6;
  return true;
}

}  // namespace

std::optional<DateTimeLiteral> scan_datetime(std::string_view s) {
  DateTimeLiteral lit{Type::DateLocal, {}, 0};
  std::size_t pos = 0;
  if (digits_at(s, 0, 4)) {
    if (!scan_date(s, pos, lit.text)) return std::nullopt;
    bool sep_t = pos < s.size() && (s[pos] == 'T' || s[pos] == 't');
    // A space only joins a date and a time when a time follows it.
    bool sep_sp = pos + 3 < s.size() && s[pos] == ' ' && is_digit(s[pos + 1]) &&
                  is_digit(s[pos + 2]) && s[pos + 3] == ':';
    if (sep_t || sep_sp) {
      lit.text.push_back('T');
      ++pos;
      if (!scan_time(s, pos, lit.text)) return std::nullopt;
      lit.type = Type::DateTimeLocal;
      std::size_t save = pos;
      std::string off;
      if (scan_offset(s, pos, off)) {
        lit.text += off;
        lit.type = Type::DateTime;
      } else {
        pos = save;
      }
    }
  } else {
    if (!scan_time(s, pos, lit.text)) return std::nullopt;
    lit.type = Type::TimeLocal;
  }
  lit.length = pos;
  return lit;
}

}  // namespace toml
