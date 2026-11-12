// Signed arbitrary-precision integers.
#pragma once

#include <compare>
#include <cstdint>
#include <iosfwd>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

#include "bigint/magnitude.hpp"

namespace bigint {

/// Thrown by division, remainder and exponentiation on arguments with no result.
class ArithmeticError : public std::domain_error {
 public:
  using std::domain_error::domain_error;
};

/// A signed integer of unbounded size, stored as sign + base-10^9 magnitude.
///
/// Values are always canonical: zero has no sign ("negative zero" does not
/// exist), so equality and printing never see `-0`.
class BigInt {
 public:
  /// Zero.
  BigInt() = default;
  /// Implicit conversion from any machine integer.
  BigInt(std::int64_t value);  // NOLINT(google-explicit-constructor)

  /// Parses `-?[0-9]+`. Leading zeros and `-0` are accepted.
  /// Throws std::invalid_argument for any other text.
  explicit BigInt(std::string_view text);

  /// Canonical decimal text: no leading zeros, `-` only for negative values.
  std::string to_string() const;

  bool is_zero() const noexcept { return mag_.empty(); }
  bool is_negative() const noexcept { return negative_; }
  /// -1, 0 or 1.
  int sign() const noexcept { return is_zero() ? 0 : (negative_ ? -1 : 1); }

  BigInt operator-() const;
  BigInt abs() const;

  BigInt& operator+=(const BigInt& rhs);
  BigInt& operator-=(const BigInt& rhs);
  BigInt& operator*=(const BigInt& rhs);
  /// Truncating division. Throws ArithmeticError if `rhs` is zero.
  BigInt& operator/=(const BigInt& rhs);
  /// Remainder with the sign of the dividend. Throws if `rhs` is zero.
  BigInt& operator%=(const BigInt& rhs);

  friend BigInt operator+(BigInt a, const BigInt& b) { return a += b; }
  friend BigInt operator-(BigInt a, const BigInt& b) { return a -= b; }
  friend BigInt operator*(BigInt a, const BigInt& b) { return a *= b; }
  friend BigInt operator/(BigInt a, const BigInt& b) { return a /= b; }
  friend BigInt operator%(BigInt a, const BigInt& b) { return a %= b; }

  friend bool operator==(const BigInt& a, const BigInt& b) noexcept {
    return a.negative_ == b.negative_ && a.mag_ == b.mag_;
  }
  friend std::strong_ordering operator<=>(const BigInt& a, const BigInt& b) noexcept;

  /// Quotient and remainder together (one pass of long division), so that
  /// a == q * b + r, |r| < |b| and r is zero or has the sign of a.
  /// Throws ArithmeticError if `b` is zero.
  static std::pair<BigInt, BigInt> divmod(const BigInt& a, const BigInt& b);

  /// base^exp by repeated squaring; `0^0 == 1`.
  static BigInt pow(const BigInt& base, std::uint64_t exp);
  /// base^exp for a BigInt exponent. Throws ArithmeticError if `exp` is
  /// negative, or if it does not fit in 64 bits and the base is not 0, 1 or -1
  /// (the result could not be represented in memory).
  static BigInt pow(const BigInt& base, const BigInt& exp);

 private:
  BigInt(bool negative, mag::Magnitude&& magnitude);

  bool negative_ = false;
  mag::Magnitude mag_;  // little-endian, base 10^9, canonical
};

std::ostream& operator<<(std::ostream& os, const BigInt& v);

}  // namespace bigint
