#include "numfmt.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace langvm {

std::string formatFloatFixed(double x, int digits) {
  if (std::isnan(x)) return "nan";
  if (std::isinf(x)) return x > 0 ? "inf" : "-inf";
  char buf[512];
  std::snprintf(buf, sizeof buf, "%.*f", digits, x);
  return buf;
}

std::string formatIntRadix(int64_t x, int radix) {
  uint64_t mag = x < 0 ? 0 - static_cast<uint64_t>(x) : static_cast<uint64_t>(x);
  std::string s;
  if (mag == 0) s = "0";
  while (mag) {
    int d = static_cast<int>(mag % static_cast<uint64_t>(radix));
    s.push_back(static_cast<char>(d < 10 ? '0' + d : 'a' + d - 10));
    mag /= static_cast<uint64_t>(radix);
  }
  if (x < 0) s.push_back('-');
  return std::string(s.rbegin(), s.rend());
}

bool parseIntText(const std::u32string& s, int radix, int64_t& out) {
  size_t i = 0;
  bool neg = false;
  if (i < s.size() && (s[i] == '+' || s[i] == '-')) {
    neg = s[i] == '-';
    ++i;
  }
  if (i >= s.size()) return false;
  uint64_t limit = neg ? (1ull << 63) : (1ull << 63) - 1;
  uint64_t v = 0;
  for (; i < s.size(); ++i) {
    char32_t c = s[i];
    int d;
    if (c >= '0' && c <= '9') d = static_cast<int>(c - '0');
    else if (c >= 'a' && c <= 'z') d = static_cast<int>(c - 'a') + 10;
    else if (c >= 'A' && c <= 'Z') d = static_cast<int>(c - 'A') + 10;
    else return false;
    if (d >= radix) return false;
    unsigned __int128 nv = static_cast<unsigned __int128>(v) * static_cast<unsigned>(radix) + static_cast<unsigned>(d);
    if (nv > limit) return false;
    v = static_cast<uint64_t>(nv);
  }
  out = neg ? static_cast<int64_t>(0 - v) : static_cast<int64_t>(v);
  return true;
}

bool parseFloatText(const std::u32string& s, double& out) {
  std::string t;
  size_t i = 0, n = s.size();
  auto digit = [&](size_t k) { return k < n && s[k] >= '0' && s[k] <= '9'; };
  for (char32_t c : s)
    if (c > 127) return false;
  if (i < n && (s[i] == '+' || s[i] == '-')) ++i;
  size_t intStart = i;
  while (digit(i)) ++i;
  size_t intDigits = i - intStart;
  size_t fracDigits = 0;
  if (i < n && s[i] == '.') {
    ++i;
    size_t fs = i;
    while (digit(i)) ++i;
    fracDigits = i - fs;
  }
  if (intDigits == 0 && fracDigits == 0) return false;
  if (i < n && (s[i] == 'e' || s[i] == 'E')) {
    ++i;
    if (i < n && (s[i] == '+' || s[i] == '-')) ++i;
    size_t es = i;
    while (digit(i)) ++i;
    if (i == es) return false;
  }
  if (i != n) return false;
  for (char32_t c : s) t.push_back(static_cast<char>(c));
  out = std::strtod(t.c_str(), nullptr);
  return true;
}

}  // namespace langvm
