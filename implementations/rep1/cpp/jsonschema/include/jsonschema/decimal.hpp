// Exact decimal numbers: the number model of JSON Schema as used by this library.
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace jsonschema {

/// An exact rational of the form  sign * digits * 10^exponent.
///
/// Values are kept normalised (no leading or trailing zeros in the mantissa,
/// zero has a single representation), so two numbers are equal exactly when
/// their fields are equal. No binary floating point is involved anywhere.
class Decimal {
 public:
  /// Zero.
  Decimal() = default;

  /// Exact conversion from an unsigned integer.
  static Decimal from_uint(std::uint64_t v);

  /// Parses a JSON number literal (RFC 8259 grammar). Returns nullopt when
  /// `literal` is not exactly one well-formed number.
  static std::optional<Decimal> parse(std::string_view literal);

  bool is_zero() const noexcept { return digits_.empty(); }
  bool is_negative() const noexcept { return negative_; }
  /// True when the value is a whole number (`1.0`, `1e2` and `-0` are integers).
  bool is_integer() const noexcept { return digits_.empty() || exponent_ >= 0; }

  /// Three-way comparison: negative, zero or positive.
  int compare(const Decimal& other) const noexcept;

  /// True when `*this / divisor` is a whole number. Zero is a multiple of
  /// everything; nothing is a multiple of zero.
  bool is_multiple_of(const Decimal& divisor) const;

  /// For a non-negative integer, its value saturated to UINT64_MAX; for
  /// anything else, nullopt.
  std::optional<std::uint64_t> to_count() const noexcept;

  std::size_t hash() const noexcept;

  /// Canonical text form (plain notation for small exponents, otherwise `<digits>e<exp>`).
  std::string to_string() const;

  friend bool operator==(const Decimal& a, const Decimal& b) noexcept {
    return a.negative_ == b.negative_ && a.exponent_ == b.exponent_ && a.digits_ == b.digits_;
  }
  friend bool operator!=(const Decimal& a, const Decimal& b) noexcept { return !(a == b); }

 private:
  static Decimal normalised(bool negative, std::string digits, std::int64_t exponent);

  bool negative_ = false;
  std::int64_t exponent_ = 0;
  std::string digits_;  // decimal digits, most significant first; empty means zero
};

}  // namespace jsonschema
