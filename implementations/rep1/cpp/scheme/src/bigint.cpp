#include "scheme/bigint.hpp"

#include <algorithm>

namespace scheme {

namespace {

using Mag = std::vector<uint32_t>;
constexpr uint64_t kBase = uint64_t(1) << 32;

void trim(Mag& m) {
  while (!m.empty() && m.back() == 0) m.pop_back();
}

int cmp_mag(const Mag& a, const Mag& b) {
  if (a.size() != b.size()) return a.size() < b.size() ? -1 : 1;
  for (size_t i = a.size(); i-- > 0;) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

Mag add_mag(const Mag& a, const Mag& b) {
  const Mag& big = a.size() >= b.size() ? a : b;
  const Mag& small = a.size() >= b.size() ? b : a;
  Mag r;
  r.reserve(big.size() + 1);
  uint64_t carry = 0;
  for (size_t i = 0; i < big.size(); ++i) {
    uint64_t s = uint64_t(big[i]) + (i < small.size() ? small[i] : 0) + carry;
    r.push_back(uint32_t(s));
    carry = s >> 32;
  }
  if (carry) r.push_back(uint32_t(carry));
  return r;
}

// Requires a >= b.
Mag sub_mag(const Mag& a, const Mag& b) {
  Mag r;
  r.reserve(a.size());
  int64_t borrow = 0;
  for (size_t i = 0; i < a.size(); ++i) {
    int64_t d = int64_t(a[i]) - (i < b.size() ? int64_t(b[i]) : 0) - borrow;
    if (d < 0) {
      d += int64_t(kBase);
      borrow = 1;
    } else {
      borrow = 0;
    }
    r.push_back(uint32_t(d));
  }
  trim(r);
  return r;
}

Mag mul_mag(const Mag& a, const Mag& b) {
  if (a.empty() || b.empty()) return {};
  Mag r(a.size() + b.size(), 0);
  for (size_t i = 0; i < a.size(); ++i) {
    uint64_t carry = 0;
    uint64_t ai = a[i];
    for (size_t j = 0; j < b.size(); ++j) {
      uint64_t t = ai * b[j] + r[i + j] + carry;
      r[i + j] = uint32_t(t);
      carry = t >> 32;
    }
    r[i + b.size()] = uint32_t(carry);
  }
  trim(r);
  return r;
}

// In-place division by a small value; returns the remainder.
uint32_t divmod_small(Mag& m, uint32_t d) {
  uint64_t rem = 0;
  for (size_t i = m.size(); i-- > 0;) {
    uint64_t cur = (rem << 32) | m[i];
    m[i] = uint32_t(cur / d);
    rem = cur % d;
  }
  trim(m);
  return uint32_t(rem);
}

// m = m * mul + add
void mul_add_small(Mag& m, uint32_t mul, uint32_t add) {
  uint64_t carry = add;
  for (auto& limb : m) {
    uint64_t t = uint64_t(limb) * mul + carry;
    limb = uint32_t(t);
    carry = t >> 32;
  }
  if (carry) m.push_back(uint32_t(carry));
}

// Knuth, TAOCP vol. 2, 4.3.1, Algorithm D.  v must be nonzero.
void divmod_mag(const Mag& u, const Mag& v, Mag& q, Mag& r) {
  if (cmp_mag(u, v) < 0) {
    q.clear();
    r = u;
    return;
  }
  if (v.size() == 1) {
    q = u;
    uint32_t rem = divmod_small(q, v[0]);
    r.clear();
    if (rem) r.push_back(rem);
    return;
  }
  const size_t n = v.size();
  const size_t m = u.size() - n;
  const int s = __builtin_clz(v.back());

  Mag vn(n);
  Mag un(u.size() + 1);
  if (s == 0) {
    std::copy(v.begin(), v.end(), vn.begin());
    std::copy(u.begin(), u.end(), un.begin());
    un[u.size()] = 0;
  } else {
    for (size_t i = n - 1; i > 0; --i) vn[i] = (v[i] << s) | (v[i - 1] >> (32 - s));
    vn[0] = v[0] << s;
    un[u.size()] = u.back() >> (32 - s);
    for (size_t i = u.size() - 1; i > 0; --i) un[i] = (u[i] << s) | (u[i - 1] >> (32 - s));
    un[0] = u[0] << s;
  }

  q.assign(m + 1, 0);
  for (size_t j = m + 1; j-- > 0;) {
    uint64_t num = (uint64_t(un[j + n]) << 32) | un[j + n - 1];
    uint64_t qhat = num / vn[n - 1];
    uint64_t rhat = num % vn[n - 1];
    while (qhat >= kBase || qhat * vn[n - 2] > ((rhat << 32) | un[j + n - 2])) {
      --qhat;
      rhat += vn[n - 1];
      if (rhat >= kBase) break;
    }
    // Multiply and subtract.
    int64_t borrow = 0;
    uint64_t carry = 0;
    for (size_t i = 0; i < n; ++i) {
      uint64_t p = qhat * vn[i] + carry;
      carry = p >> 32;
      int64_t t = int64_t(un[i + j]) - borrow - int64_t(p & 0xffffffffu);
      un[i + j] = uint32_t(t);
      borrow = t < 0 ? 1 : 0;
    }
    int64_t t = int64_t(un[j + n]) - borrow - int64_t(carry);
    un[j + n] = uint32_t(t);
    if (t < 0) {
      // qhat was one too large: add the divisor back.
      --qhat;
      uint64_t c = 0;
      for (size_t i = 0; i < n; ++i) {
        uint64_t sum = uint64_t(un[i + j]) + vn[i] + c;
        un[i + j] = uint32_t(sum);
        c = sum >> 32;
      }
      un[j + n] = uint32_t(uint64_t(un[j + n]) + c);
    }
    q[j] = uint32_t(qhat);
  }
  trim(q);

  r.assign(n, 0);
  if (s == 0) {
    std::copy(un.begin(), un.begin() + n, r.begin());
  } else {
    for (size_t i = 0; i < n; ++i) r[i] = (un[i] >> s) | (uint32_t(uint64_t(un[i + 1]) << (32 - s)));
  }
  trim(r);
}

}  // namespace

BigInt::BigInt(bool neg, Mag mag) : neg_(neg), mag_(std::move(mag)) { normalize(); }

BigInt::BigInt(int64_t v) {
  uint64_t u = v < 0 ? ~uint64_t(v) + 1 : uint64_t(v);
  neg_ = v < 0;
  while (u) {
    mag_.push_back(uint32_t(u));
    u >>= 32;
  }
}

void BigInt::normalize() {
  trim(mag_);
  if (mag_.empty()) neg_ = false;
}

BigInt BigInt::from_decimal(std::string_view text) {
  bool neg = false;
  size_t i = 0;
  if (i < text.size() && (text[i] == '+' || text[i] == '-')) {
    neg = text[i] == '-';
    ++i;
  }
  Mag mag;
  while (i < text.size()) {
    size_t take = std::min<size_t>(9, text.size() - i);
    uint32_t chunk = 0, scale = 1;
    for (size_t k = 0; k < take; ++k) {
      chunk = chunk * 10 + uint32_t(text[i + k] - '0');
      scale *= 10;
    }
    mul_add_small(mag, scale, chunk);
    i += take;
  }
  return BigInt(neg, std::move(mag));
}

bool BigInt::fits_int64() const {
  if (mag_.size() > 2) return false;
  uint64_t u = 0;
  for (size_t i = mag_.size(); i-- > 0;) u = (u << 32) | mag_[i];
  return neg_ ? u <= (uint64_t(1) << 63) : u < (uint64_t(1) << 63);
}

int64_t BigInt::to_int64() const {
  uint64_t u = 0;
  for (size_t i = mag_.size(); i-- > 0;) u = (u << 32) | mag_[i];
  return neg_ ? int64_t(~u + 1) : int64_t(u);
}

std::string BigInt::to_string() const {
  if (mag_.empty()) return "0";
  Mag m = mag_;
  std::vector<uint32_t> chunks;
  while (!m.empty()) chunks.push_back(divmod_small(m, 1000000000u));
  std::string out;
  if (neg_) out.push_back('-');
  out += std::to_string(chunks.back());
  for (size_t i = chunks.size() - 1; i-- > 0;) {
    std::string part = std::to_string(chunks[i]);
    out.append(9 - part.size(), '0');
    out += part;
  }
  return out;
}

BigInt BigInt::operator-() const {
  BigInt r = *this;
  if (!r.mag_.empty()) r.neg_ = !r.neg_;
  return r;
}

BigInt operator+(const BigInt& a, const BigInt& b) {
  if (a.neg_ == b.neg_) return BigInt(a.neg_, add_mag(a.mag_, b.mag_));
  int c = cmp_mag(a.mag_, b.mag_);
  if (c == 0) return BigInt();
  if (c > 0) return BigInt(a.neg_, sub_mag(a.mag_, b.mag_));
  return BigInt(b.neg_, sub_mag(b.mag_, a.mag_));
}

BigInt operator-(const BigInt& a, const BigInt& b) { return a + (-b); }

BigInt operator*(const BigInt& a, const BigInt& b) {
  return BigInt(a.neg_ != b.neg_, mul_mag(a.mag_, b.mag_));
}

void BigInt::divmod(const BigInt& a, const BigInt& b, BigInt& q, BigInt& r) {
  Mag qm, rm;
  divmod_mag(a.mag_, b.mag_, qm, rm);
  bool qneg = a.neg_ != b.neg_;
  bool rneg = a.neg_;
  q = BigInt(qneg, std::move(qm));
  r = BigInt(rneg, std::move(rm));
}

int BigInt::compare(const BigInt& a, const BigInt& b) {
  if (a.neg_ != b.neg_) return a.neg_ ? -1 : 1;
  int c = cmp_mag(a.mag_, b.mag_);
  return a.neg_ ? -c : c;
}

}  // namespace scheme
