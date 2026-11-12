// Signed arbitrary-precision integers.
//
//   bigint::BigInt a("123456789012345678901234567890");
//   bigint::BigInt b = a * a - 1;
//   std::cout << b / 7 << '\n';
//
// Values are a sign plus a base-10^9 magnitude (see magnitude.hpp). Zero is
// never negative. Division truncates toward zero and the remainder takes the
// sign of the dividend (C semantics).
#pragma once

#include <cstdint>
#include <iosfwd>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

#include "bigint/magnitude.hpp"

namespace bigint {

/// Thrown by BigInt(std::string_view) when the text is not `-?[0-9]+`.
class ParseError : public std::invalid_argument {
public:
    using std::invalid_argument::invalid_argument;
};

class BigInt {
public:
    /// Zero.
    BigInt() = default;

    /// From a machine integer.
    BigInt(std::int64_t value);  // NOLINT(google-explicit-constructor)
    BigInt(int value) : BigInt(static_cast<std::int64_t>(value)) {}  // NOLINT; avoids literal 0 -> const char* ambiguity

    /// From decimal text matching `-?[0-9]+`. Leading zeros and "-0" are
    /// accepted. Throws ParseError otherwise.
    explicit BigInt(std::string_view decimal);
    explicit BigInt(const char* decimal) : BigInt(std::string_view(decimal)) {}
    explicit BigInt(const std::string& decimal) : BigInt(std::string_view(decimal)) {}

    /// Canonical decimal form: no leading zeros, "-" only for negatives.
    std::string to_string() const;

    bool is_zero() const { return mag_.empty(); }
    bool is_negative() const { return neg_; }
    /// -1, 0 or 1.
    int sign() const { return mag_.empty() ? 0 : (neg_ ? -1 : 1); }

    /// Value as uint64 if it is non-negative and fits; otherwise throws
    /// std::overflow_error.
    std::uint64_t to_uint64() const;

    BigInt operator-() const;
    BigInt abs() const;

    BigInt& operator+=(const BigInt& rhs);
    BigInt& operator-=(const BigInt& rhs);
    BigInt& operator*=(const BigInt& rhs);
    /// Truncating division; throws std::domain_error if rhs is zero.
    BigInt& operator/=(const BigInt& rhs);
    /// Remainder with the sign of the dividend; throws std::domain_error if
    /// rhs is zero.
    BigInt& operator%=(const BigInt& rhs);

    friend BigInt operator+(BigInt a, const BigInt& b) { return a += b; }
    friend BigInt operator-(BigInt a, const BigInt& b) { return a -= b; }
    friend BigInt operator*(BigInt a, const BigInt& b) { return a *= b; }
    friend BigInt operator/(BigInt a, const BigInt& b) { return a /= b; }
    friend BigInt operator%(BigInt a, const BigInt& b) { return a %= b; }

    /// Quotient and remainder together (one Algorithm D run).
    /// Throws std::domain_error if divisor is zero.
    static std::pair<BigInt, BigInt> divmod(const BigInt& dividend, const BigInt& divisor);

    /// base^exponent by repeated squaring; pow(x, 0) == 1 for every x,
    /// including 0.
    static BigInt pow(const BigInt& base, std::uint64_t exponent);

    /// Three-way comparison: -1, 0 or 1.
    static int compare(const BigInt& a, const BigInt& b);

    friend bool operator==(const BigInt& a, const BigInt& b) { return compare(a, b) == 0; }
    friend bool operator!=(const BigInt& a, const BigInt& b) { return compare(a, b) != 0; }
    friend bool operator<(const BigInt& a, const BigInt& b) { return compare(a, b) < 0; }
    friend bool operator<=(const BigInt& a, const BigInt& b) { return compare(a, b) <= 0; }
    friend bool operator>(const BigInt& a, const BigInt& b) { return compare(a, b) > 0; }
    friend bool operator>=(const BigInt& a, const BigInt& b) { return compare(a, b) >= 0; }

private:
    BigInt(bool negative, mag::Magnitude magnitude);

    bool neg_ = false;      // invariant: false when mag_ is empty
    mag::Magnitude mag_;    // canonical, little-endian, base 10^9
};

std::ostream& operator<<(std::ostream& os, const BigInt& v);

}  // namespace bigint
