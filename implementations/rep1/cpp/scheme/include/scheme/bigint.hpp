/// \file bigint.hpp
/// Arbitrary-precision signed integers (sign + magnitude, base 2^32).
///
/// Classical algorithms only: schoolbook multiplication, Knuth's Algorithm D
/// for division, repeated division by 10^9 for decimal output.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace scheme {

class BigInt {
 public:
  BigInt() = default;
  BigInt(int64_t v);  // NOLINT: implicit by design

  /// Parse an optional sign followed by one or more ASCII digits.
  static BigInt from_decimal(std::string_view text);

  bool is_zero() const { return mag_.empty(); }
  bool is_negative() const { return neg_; }
  bool fits_int64() const;
  /// Value as int64; only valid when fits_int64().
  int64_t to_int64() const;
  std::string to_string() const;

  BigInt operator-() const;
  friend BigInt operator+(const BigInt& a, const BigInt& b);
  friend BigInt operator-(const BigInt& a, const BigInt& b);
  friend BigInt operator*(const BigInt& a, const BigInt& b);

  /// Truncating division: a = q*b + r, r has the sign of a. `b` must be nonzero.
  static void divmod(const BigInt& a, const BigInt& b, BigInt& q, BigInt& r);

  /// -1, 0 or 1.
  static int compare(const BigInt& a, const BigInt& b);
  friend bool operator==(const BigInt& a, const BigInt& b) { return compare(a, b) == 0; }
  friend bool operator!=(const BigInt& a, const BigInt& b) { return compare(a, b) != 0; }
  friend bool operator<(const BigInt& a, const BigInt& b) { return compare(a, b) < 0; }
  friend bool operator<=(const BigInt& a, const BigInt& b) { return compare(a, b) <= 0; }
  friend bool operator>(const BigInt& a, const BigInt& b) { return compare(a, b) > 0; }
  friend bool operator>=(const BigInt& a, const BigInt& b) { return compare(a, b) >= 0; }

 private:
  using Mag = std::vector<uint32_t>;  // little endian, no leading zero limbs
  BigInt(bool neg, Mag mag);
  void normalize();

  bool neg_ = false;
  Mag mag_;
};

}  // namespace scheme
