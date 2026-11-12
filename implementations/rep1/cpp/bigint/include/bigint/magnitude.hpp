// Unsigned magnitude arithmetic: the low-level, sign-free layer under BigInt.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace bigint::mag {

/// A natural number as little-endian limbs in base 10^9. The canonical form
/// has no most-significant zero limbs; zero is the empty vector.
using Magnitude = std::vector<std::uint32_t>;

/// Decimal base of one limb.
inline constexpr std::uint32_t kBase = 1'000'000'000;
/// Decimal digits per limb.
inline constexpr int kBaseDigits = 9;

/// Removes most-significant zero limbs.
void trim(Magnitude& m);

/// Parses a string of ASCII digits (leading zeros allowed, may be empty).
/// Throws std::invalid_argument on any other character. O(n).
Magnitude from_digits(std::string_view digits);

/// Appends the decimal digits of `m` (no leading zeros; "0" for zero). O(n).
void append_digits(const Magnitude& m, std::string& out);

/// Three-way comparison of canonical magnitudes: -1, 0 or 1. O(n).
int compare(const Magnitude& a, const Magnitude& b);

/// a + b. O(n + m).
Magnitude add(const Magnitude& a, const Magnitude& b);

/// a - b; requires a >= b. O(n).
Magnitude sub(const Magnitude& a, const Magnitude& b);

/// a * b by schoolbook long multiplication. O(n * m).
Magnitude mul(const Magnitude& a, const Magnitude& b);

/// Quotient and remainder (Knuth's Algorithm D); requires b != 0.
/// O((n - m + 1) * m).
std::pair<Magnitude, Magnitude> divmod(const Magnitude& a, const Magnitude& b);

/// base^exp by binary exponentiation.
Magnitude pow(const Magnitude& base, std::uint64_t exp);

}  // namespace bigint::mag
