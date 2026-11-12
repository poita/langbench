#include "jsonschema/decimal.hpp"

#include <algorithm>
#include <functional>
#include <limits>
#include <vector>

namespace jsonschema {

namespace {

constexpr std::uint32_t kBase = 1000000000u;  // limbs hold 9 decimal digits
using Limbs = std::vector<std::uint32_t>;     // little endian

Limbs to_limbs(const std::string& digits) {
  Limbs out;
  std::ptrdiff_t end = static_cast<std::ptrdiff_t>(digits.size());
  while (end > 0) {
    std::ptrdiff_t start = std::max<std::ptrdiff_t>(0, end - 9);
    std::uint32_t v = 0;
    for (std::ptrdiff_t i = start; i < end; ++i) v = v * 10 + static_cast<std::uint32_t>(digits[i] - '0');
    out.push_back(v);
    end = start;
  }
  while (!out.empty() && out.back() == 0) out.pop_back();
  return out;
}

void trim(Limbs& v) {
  while (!v.empty() && v.back() == 0) v.pop_back();
}

int compare_limbs(const Limbs& a, const Limbs& b) {
  if (a.size() != b.size()) return a.size() < b.size() ? -1 : 1;
  for (std::size_t i = a.size(); i-- > 0;) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

Limbs mul_small(const Limbs& a, std::uint32_t q) {
  Limbs out;
  out.reserve(a.size() + 1);
  std::uint64_t carry = 0;
  for (std::uint32_t limb : a) {
    std::uint64_t cur = static_cast<std::uint64_t>(limb) * q + carry;
    out.push_back(static_cast<std::uint32_t>(cur % kBase));
    carry = cur / kBase;
  }
  if (carry) out.push_back(static_cast<std::uint32_t>(carry));
  trim(out);
  return out;
}

void sub_in_place(Limbs& a, const Limbs& b) {  // requires a >= b
  std::int64_t borrow = 0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    std::int64_t cur = static_cast<std::int64_t>(a[i]) - borrow - (i < b.size() ? b[i] : 0);
    if (cur < 0) {
      cur += kBase;
      borrow = 1;
    } else {
      borrow = 0;
    }
    a[i] = static_cast<std::uint32_t>(cur);
  }
  trim(a);
}

// True when the integer written in `a` is divisible by the (non-zero) integer written in `b`.
bool divisible(const std::string& a, const std::string& b) {
  if (b == "1") return true;
  if (a.size() < b.size()) return false;
  const Limbs A = to_limbs(a);
  const Limbs B = to_limbs(b);
  if (B.size() == 1) {
    std::uint64_t rem = 0;
    for (std::size_t i = A.size(); i-- > 0;) rem = (rem * kBase + A[i]) % B[0];
    return rem == 0;
  }
  Limbs r;
  for (std::size_t i = A.size(); i-- > 0;) {
    r.insert(r.begin(), A[i]);
    trim(r);
    if (compare_limbs(r, B) < 0) continue;
    std::uint32_t lo = 1, hi = kBase - 1;  // largest q with B*q <= r
    while (lo < hi) {
      std::uint32_t mid = lo + (hi - lo + 1) / 2;
      if (compare_limbs(mul_small(B, mid), r) <= 0) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    sub_in_place(r, mul_small(B, lo));
  }
  return r.empty();
}

}  // namespace

Decimal Decimal::normalised(bool negative, std::string digits, std::int64_t exponent) {
  std::size_t first = digits.find_first_not_of('0');
  Decimal d;
  if (first == std::string::npos) return d;  // zero
  digits.erase(0, first);
  while (digits.back() == '0') {
    digits.pop_back();
    ++exponent;
  }
  d.negative_ = negative;
  d.exponent_ = exponent;
  d.digits_ = std::move(digits);
  return d;
}

Decimal Decimal::from_uint(std::uint64_t v) { return normalised(false, std::to_string(v), 0); }

std::optional<Decimal> Decimal::parse(std::string_view s) {
  std::size_t i = 0;
  const std::size_t n = s.size();
  bool negative = false;
  if (i < n && s[i] == '-') {
    negative = true;
    ++i;
  }
  auto is_digit = [&](std::size_t k) { return k < n && s[k] >= '0' && s[k] <= '9'; };
  std::string digits;
  std::size_t start = i;
  while (is_digit(i)) digits.push_back(s[i++]);
  if (i == start) return std::nullopt;
  std::int64_t frac = 0;
  if (i < n && s[i] == '.') {
    ++i;
    std::size_t fs = i;
    while (is_digit(i)) {
      digits.push_back(s[i++]);
      ++frac;
    }
    if (i == fs) return std::nullopt;
  }
  std::int64_t exp = 0;
  if (i < n && (s[i] == 'e' || s[i] == 'E')) {
    ++i;
    bool eneg = false;
    if (i < n && (s[i] == '+' || s[i] == '-')) {
      eneg = s[i] == '-';
      ++i;
    }
    std::size_t es = i;
    while (is_digit(i)) {
      if (exp < 1000000000000LL) exp = exp * 10 + (s[i] - '0');
      ++i;
    }
    if (i == es) return std::nullopt;
    if (eneg) exp = -exp;
  }
  if (i != n) return std::nullopt;
  return normalised(negative, std::move(digits), exp - frac);
}

int Decimal::compare(const Decimal& o) const noexcept {
  int sa = is_zero() ? 0 : (negative_ ? -1 : 1);
  int sb = o.is_zero() ? 0 : (o.negative_ ? -1 : 1);
  if (sa != sb) return sa < sb ? -1 : 1;
  if (sa == 0) return 0;
  std::int64_t ea = static_cast<std::int64_t>(digits_.size()) + exponent_;
  std::int64_t eb = static_cast<std::int64_t>(o.digits_.size()) + o.exponent_;
  int mag;
  if (ea != eb) {
    mag = ea < eb ? -1 : 1;
  } else {
    int c = digits_.compare(o.digits_);
    mag = c < 0 ? -1 : (c > 0 ? 1 : 0);
  }
  return sa > 0 ? mag : -mag;
}

bool Decimal::is_multiple_of(const Decimal& d) const {
  if (is_zero()) return true;
  if (d.is_zero()) return false;
  std::string a = digits_, b = d.digits_;
  std::int64_t diff = exponent_ - d.exponent_;
  if (diff >= 0) {
    a.append(static_cast<std::size_t>(diff), '0');
  } else {
    b.append(static_cast<std::size_t>(-diff), '0');
  }
  return divisible(a, b);
}

std::optional<std::uint64_t> Decimal::to_count() const noexcept {
  if (is_zero()) return 0;
  if (negative_ || exponent_ < 0) return std::nullopt;
  if (static_cast<std::int64_t>(digits_.size()) + exponent_ > 19) return std::numeric_limits<std::uint64_t>::max();
  std::uint64_t v = 0;
  for (char c : digits_) v = v * 10 + static_cast<std::uint64_t>(c - '0');
  for (std::int64_t k = 0; k < exponent_; ++k) v *= 10;
  return v;
}

std::size_t Decimal::hash() const noexcept {
  std::size_t h = std::hash<std::string>{}(digits_);
  h ^= std::hash<std::int64_t>{}(exponent_) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
  if (negative_) h = ~h;
  return h;
}

std::string Decimal::to_string() const {
  if (is_zero()) return "0";
  std::string out = negative_ ? "-" : "";
  const std::int64_t len = static_cast<std::int64_t>(digits_.size());
  if (exponent_ >= 0 && exponent_ <= 20) {
    out += digits_;
    out.append(static_cast<std::size_t>(exponent_), '0');
  } else if (exponent_ < 0 && -exponent_ <= 20) {
    std::int64_t point = len + exponent_;  // digits before the decimal point
    if (point > 0) {
      out += digits_.substr(0, static_cast<std::size_t>(point));
      out += '.';
      out += digits_.substr(static_cast<std::size_t>(point));
    } else {
      out += "0.";
      out.append(static_cast<std::size_t>(-point), '0');
      out += digits_;
    }
  } else {
    out += digits_;
    out += 'e';
    out += std::to_string(exponent_);
  }
  return out;
}

}  // namespace jsonschema
