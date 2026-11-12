#include "toml/number.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace toml {

namespace {

int digit_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return 99;
}

// Scans `digit ( "_"? digit )*` where digits have value < base, starting at
// `i`; advances `i` past it. Returns false when no valid sequence starts here.
bool scan_digits(std::string_view s, std::size_t& i, int base) {
  if (i >= s.size() || digit_value(s[i]) >= base) return false;
  ++i;
  while (i < s.size()) {
    if (digit_value(s[i]) < base) {
      ++i;
    } else if (s[i] == '_' && i + 1 < s.size() && digit_value(s[i + 1]) < base) {
      i += 2;
    } else {
      break;
    }
  }
  return true;
}

// `"0" | [1-9] ( "_"? [0-9] )*`
bool scan_dec_int(std::string_view s, std::size_t& i) {
  if (i < s.size() && s[i] == '0') {
    ++i;
    return true;
  }
  if (i >= s.size() || s[i] == '0') return false;
  return scan_digits(s, i, 10);
}

}  // namespace

std::optional<std::string> canonical_integer(std::string_view lit) {
  std::size_t i = 0;
  bool neg = false;
  int base = 10;
  if (lit.size() > 1 && lit[0] == '0' && (lit[1] == 'x' || lit[1] == 'o' || lit[1] == 'b')) {
    base = lit[1] == 'x' ? 16 : lit[1] == 'o' ? 8 : 2;
    i = 2;
    if (!scan_digits(lit, i, base) || i != lit.size()) return std::nullopt;
    lit.remove_prefix(2);
  } else {
    if (!lit.empty() && (lit[0] == '+' || lit[0] == '-')) {
      neg = lit[0] == '-';
      i = 1;
    }
    std::size_t start = i;
    if (!scan_dec_int(lit, i) || i != lit.size()) return std::nullopt;
    lit.remove_prefix(start);
  }
  const std::uint64_t limit = neg ? (std::uint64_t{1} << 63) : (std::uint64_t{1} << 63) - 1;
  std::uint64_t mag = 0;
  for (char c : lit) {
    if (c == '_') continue;
    std::uint64_t d = static_cast<std::uint64_t>(digit_value(c));
    if (mag > (limit - d) / static_cast<std::uint64_t>(base)) return std::nullopt;
    mag = mag * static_cast<std::uint64_t>(base) + d;
  }
  std::string out = std::to_string(mag);
  if (neg && mag != 0) out.insert(out.begin(), '-');
  return out;
}

std::string format_float(double v) {
  if (std::isnan(v)) return "nan";
  if (std::isinf(v)) return v < 0 ? "-inf" : "inf";
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.16e", v);
  return buf;
}

std::optional<std::string> canonical_float(std::string_view lit) {
  std::size_t i = 0;
  bool neg = false;
  if (!lit.empty() && (lit[0] == '+' || lit[0] == '-')) {
    neg = lit[0] == '-';
    i = 1;
  }
  std::string_view rest = lit.substr(i);
  if (rest == "inf") return neg ? "-inf" : "inf";
  if (rest == "nan") return "nan";

  if (!scan_dec_int(lit, i)) return std::nullopt;
  bool has_frac = false, has_exp = false;
  if (i < lit.size() && lit[i] == '.') {
    ++i;
    if (!scan_digits(lit, i, 10)) return std::nullopt;
    has_frac = true;
  }
  if (i < lit.size() && (lit[i] == 'e' || lit[i] == 'E')) {
    ++i;
    if (i < lit.size() && (lit[i] == '+' || lit[i] == '-')) ++i;
    if (!scan_digits(lit, i, 10)) return std::nullopt;
    has_exp = true;
  }
  if (i != lit.size() || (!has_frac && !has_exp)) return std::nullopt;

  std::string clean;
  clean.reserve(lit.size());
  for (char c : lit)
    if (c != '_') clean.push_back(c);
  return format_float(std::strtod(clean.c_str(), nullptr));
}

}  // namespace toml
