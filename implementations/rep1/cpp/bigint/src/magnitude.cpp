#include "bigint/magnitude.hpp"

#include <algorithm>
#include <cassert>
#include <stdexcept>

namespace bigint::mag {

namespace {
constexpr std::uint64_t kB = kBase;
}

void trim(Magnitude& m) {
  while (!m.empty() && m.back() == 0) m.pop_back();
}

Magnitude from_digits(std::string_view digits) {
  for (char c : digits) {
    if (c < '0' || c > '9') throw std::invalid_argument("bigint: invalid digit");
  }
  Magnitude m;
  m.reserve(digits.size() / kBaseDigits + 1);
  std::size_t end = digits.size();
  while (end > 0) {
    std::size_t begin = end >= kBaseDigits ? end - kBaseDigits : 0;
    std::uint32_t limb = 0;
    for (std::size_t i = begin; i < end; ++i) limb = limb * 10 + (digits[i] - '0');
    m.push_back(limb);
    end = begin;
  }
  trim(m);
  return m;
}

void append_digits(const Magnitude& m, std::string& out) {
  if (m.empty()) {
    out.push_back('0');
    return;
  }
  out.reserve(out.size() + m.size() * kBaseDigits);
  char buf[kBaseDigits];
  for (std::size_t i = m.size(); i-- > 0;) {
    std::uint32_t limb = m[i];
    for (int k = kBaseDigits - 1; k >= 0; --k) {
      buf[k] = static_cast<char>('0' + limb % 10);
      limb /= 10;
    }
    int skip = 0;
    if (i + 1 == m.size()) {  // top limb: drop leading zeros
      while (skip < kBaseDigits - 1 && buf[skip] == '0') ++skip;
    }
    out.append(buf + skip, kBaseDigits - skip);
  }
}

int compare(const Magnitude& a, const Magnitude& b) {
  if (a.size() != b.size()) return a.size() < b.size() ? -1 : 1;
  for (std::size_t i = a.size(); i-- > 0;) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

Magnitude add(const Magnitude& a, const Magnitude& b) {
  const Magnitude& lo = a.size() < b.size() ? a : b;
  const Magnitude& hi = a.size() < b.size() ? b : a;
  Magnitude r;
  r.reserve(hi.size() + 1);
  std::uint32_t carry = 0;
  for (std::size_t i = 0; i < hi.size(); ++i) {
    std::uint32_t s = hi[i] + (i < lo.size() ? lo[i] : 0) + carry;  // < 2^31
    carry = s >= kBase;
    r.push_back(carry ? s - kBase : s);
  }
  if (carry) r.push_back(1);
  return r;
}

Magnitude sub(const Magnitude& a, const Magnitude& b) {
  assert(compare(a, b) >= 0);
  Magnitude r;
  r.reserve(a.size());
  std::uint32_t borrow = 0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    std::int64_t d = static_cast<std::int64_t>(a[i]) - (i < b.size() ? b[i] : 0) - borrow;
    borrow = d < 0;
    r.push_back(static_cast<std::uint32_t>(borrow ? d + kBase : d));
  }
  trim(r);
  return r;
}

Magnitude mul(const Magnitude& a, const Magnitude& b) {
  if (a.empty() || b.empty()) return {};
  Magnitude r(a.size() + b.size(), 0);
  for (std::size_t i = 0; i < a.size(); ++i) {
    std::uint64_t carry = 0;
    const std::uint64_t ai = a[i];
    if (ai == 0) continue;
    for (std::size_t j = 0; j < b.size(); ++j) {
      std::uint64_t cur = r[i + j] + ai * b[j] + carry;  // < 10^18 + 2*10^9
      carry = cur / kB;
      r[i + j] = static_cast<std::uint32_t>(cur - carry * kB);
    }
    r[i + b.size()] = static_cast<std::uint32_t>(carry);  // slot untouched so far
  }
  trim(r);
  return r;
}

namespace {

// Multiplies by a single limb (< kBase) into a vector of size m.size()+1.
Magnitude mul_small_padded(const Magnitude& m, std::uint64_t k) {
  Magnitude r(m.size() + 1);
  std::uint64_t carry = 0;
  for (std::size_t i = 0; i < m.size(); ++i) {
    std::uint64_t cur = m[i] * k + carry;
    carry = cur / kB;
    r[i] = static_cast<std::uint32_t>(cur - carry * kB);
  }
  r[m.size()] = static_cast<std::uint32_t>(carry);
  return r;
}

std::pair<Magnitude, std::uint32_t> divmod_small(const Magnitude& a, std::uint32_t d) {
  Magnitude q(a.size());
  std::uint64_t rem = 0;
  for (std::size_t i = a.size(); i-- > 0;) {
    std::uint64_t cur = rem * kB + a[i];
    q[i] = static_cast<std::uint32_t>(cur / d);
    rem = cur % d;
  }
  trim(q);
  return {std::move(q), static_cast<std::uint32_t>(rem)};
}

}  // namespace

std::pair<Magnitude, Magnitude> divmod(const Magnitude& a, const Magnitude& b) {
  if (b.empty()) throw std::domain_error("bigint: division by zero");
  if (compare(a, b) < 0) return {Magnitude{}, a};
  if (b.size() == 1) {
    auto [q, r] = divmod_small(a, b[0]);
    Magnitude rm;
    if (r) rm.push_back(r);
    return {std::move(q), std::move(rm)};
  }

  // D1: normalise so the divisor's top limb is >= kBase / 2.
  const std::size_t n = b.size();
  const std::size_t m = a.size() - n;
  const std::uint64_t d = kB / (static_cast<std::uint64_t>(b.back()) + 1);
  Magnitude v = d == 1 ? b : mul_small_padded(b, d);
  v.resize(n);  // top carry is zero by choice of d
  Magnitude u = mul_small_padded(a, d);  // a.size() + 1 limbs

  const std::uint64_t vtop = v[n - 1];
  const std::uint64_t vsec = v[n - 2];
  Magnitude q(m + 1, 0);

  for (std::size_t j = m + 1; j-- > 0;) {
    // D3: estimate the quotient digit from the top limbs.
    std::uint64_t num = static_cast<std::uint64_t>(u[j + n]) * kB + u[j + n - 1];
    std::uint64_t qhat = num / vtop;
    std::uint64_t rhat = num - qhat * vtop;
    while (qhat >= kB || qhat * vsec > rhat * kB + u[j + n - 2]) {
      --qhat;
      rhat += vtop;
      if (rhat >= kB) break;
    }

    // D4: u[j..j+n] -= qhat * v.
    std::int64_t borrow = 0;
    std::uint64_t carry = 0;
    for (std::size_t i = 0; i < n; ++i) {
      std::uint64_t p = qhat * v[i] + carry;
      carry = p / kB;
      std::int64_t t = static_cast<std::int64_t>(u[i + j]) - static_cast<std::int64_t>(p - carry * kB) - borrow;
      borrow = t < 0;
      u[i + j] = static_cast<std::uint32_t>(borrow ? t + kBase : t);
    }
    std::int64_t t = static_cast<std::int64_t>(u[j + n]) - static_cast<std::int64_t>(carry) - borrow;
    borrow = t < 0;
    u[j + n] = static_cast<std::uint32_t>(borrow ? t + kBase : t);

    // D6: qhat was one too large; add the divisor back.
    if (borrow) {
      --qhat;
      std::uint32_t c = 0;
      for (std::size_t i = 0; i < n; ++i) {
        std::uint32_t s = u[i + j] + v[i] + c;
        c = s >= kBase;
        u[i + j] = c ? s - kBase : s;
      }
      u[j + n] = static_cast<std::uint32_t>((u[j + n] + c) % kB);
    }
    q[j] = static_cast<std::uint32_t>(qhat);
  }

  // D8: un-normalise the remainder.
  u.resize(n);
  trim(u);
  Magnitude r = d == 1 ? std::move(u) : divmod_small(u, static_cast<std::uint32_t>(d)).first;
  trim(q);
  return {std::move(q), std::move(r)};
}

Magnitude pow(const Magnitude& base, std::uint64_t exp) {
  Magnitude result{1};
  if (exp == 0) return result;
  if (base.empty()) return {};
  Magnitude sq = base;
  while (true) {
    if (exp & 1) result = mul(result, sq);
    exp >>= 1;
    if (!exp) break;
    sq = mul(sq, sq);
  }
  return result;
}

}  // namespace bigint::mag
