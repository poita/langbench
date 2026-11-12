#include "bigint/bigint.hpp"

#include <ostream>

namespace bigint {

BigInt::BigInt(bool negative, mag::Magnitude&& magnitude)
    : negative_(negative && !magnitude.empty()), mag_(std::move(magnitude)) {}

BigInt::BigInt(std::int64_t value) {
  negative_ = value < 0;
  std::uint64_t u = negative_ ? 0 - static_cast<std::uint64_t>(value) : static_cast<std::uint64_t>(value);
  while (u) {
    mag_.push_back(static_cast<std::uint32_t>(u % mag::kBase));
    u /= mag::kBase;
  }
}

BigInt::BigInt(std::string_view text) {
  bool neg = !text.empty() && text.front() == '-';
  std::string_view digits = neg ? text.substr(1) : text;
  if (digits.empty()) throw std::invalid_argument("bigint: no digits");
  mag_ = mag::from_digits(digits);
  negative_ = neg && !mag_.empty();
}

std::string BigInt::to_string() const {
  std::string s;
  if (negative_) s.push_back('-');
  mag::append_digits(mag_, s);
  return s;
}

BigInt BigInt::operator-() const { return BigInt(!negative_, mag::Magnitude(mag_)); }

BigInt BigInt::abs() const { return BigInt(false, mag::Magnitude(mag_)); }

BigInt& BigInt::operator+=(const BigInt& rhs) {
  if (negative_ == rhs.negative_) {
    mag_ = mag::add(mag_, rhs.mag_);
  } else if (mag::compare(mag_, rhs.mag_) >= 0) {
    mag_ = mag::sub(mag_, rhs.mag_);
  } else {
    mag_ = mag::sub(rhs.mag_, mag_);
    negative_ = rhs.negative_;
  }
  if (mag_.empty()) negative_ = false;
  return *this;
}

BigInt& BigInt::operator-=(const BigInt& rhs) {
  if (this == &rhs) return *this = BigInt();
  return *this += -rhs;
}

BigInt& BigInt::operator*=(const BigInt& rhs) {
  negative_ = negative_ != rhs.negative_;
  mag_ = mag::mul(mag_, rhs.mag_);
  if (mag_.empty()) negative_ = false;
  return *this;
}

std::pair<BigInt, BigInt> BigInt::divmod(const BigInt& a, const BigInt& b) {
  if (b.is_zero()) throw ArithmeticError("bigint: division by zero");
  auto [q, r] = mag::divmod(a.mag_, b.mag_);
  return {BigInt(a.negative_ != b.negative_, std::move(q)), BigInt(a.negative_, std::move(r))};
}

BigInt& BigInt::operator/=(const BigInt& rhs) { return *this = divmod(*this, rhs).first; }
BigInt& BigInt::operator%=(const BigInt& rhs) { return *this = divmod(*this, rhs).second; }

std::strong_ordering operator<=>(const BigInt& a, const BigInt& b) noexcept {
  if (a.negative_ != b.negative_) return a.negative_ ? std::strong_ordering::less : std::strong_ordering::greater;
  int c = mag::compare(a.mag_, b.mag_);
  if (a.negative_) c = -c;
  return c < 0 ? std::strong_ordering::less : c > 0 ? std::strong_ordering::greater : std::strong_ordering::equal;
}

BigInt BigInt::pow(const BigInt& base, std::uint64_t exp) {
  return BigInt(base.negative_ && (exp & 1), mag::pow(base.mag_, exp));
}

BigInt BigInt::pow(const BigInt& base, const BigInt& exp) {
  if (exp.is_negative()) throw ArithmeticError("bigint: negative exponent");
  if (exp.mag_.size() <= 2) {
    std::uint64_t e = 0;
    for (std::size_t i = exp.mag_.size(); i-- > 0;) e = e * mag::kBase + exp.mag_[i];
    return pow(base, e);
  }
  // Exponent too large for 64 bits: only trivial bases have a representable result.
  if (base.is_zero()) return BigInt(0);
  if (base.mag_.size() == 1 && base.mag_[0] == 1) {
    return BigInt(base.negative_ && (exp.mag_[0] & 1), mag::Magnitude{1});
  }
  throw ArithmeticError("bigint: exponent too large");
}

std::ostream& operator<<(std::ostream& os, const BigInt& v) { return os << v.to_string(); }

}  // namespace bigint
