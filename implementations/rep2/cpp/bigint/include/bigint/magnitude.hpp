// Unsigned magnitude arithmetic in base 10^9.
//
// A magnitude is a little-endian vector of limbs, each in [0, kBase). The
// canonical form has no most-significant zero limbs, so zero is the empty
// vector. All functions take and return canonical magnitudes.
//
// Because the base is a power of ten, decimal conversion is linear in the
// number of digits. Multiplication and division are the classical
// quadratic algorithms (schoolbook, and Knuth's Algorithm D).
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace bigint::mag {

using Limb = std::uint32_t;
using Magnitude = std::vector<Limb>;

inline constexpr Limb kBase = 1'000'000'000;
inline constexpr int kBaseDigits = 9;

/// Removes most-significant zero limbs.
void trim(Magnitude& m);

/// Parses ASCII digits (no sign; leading zeros allowed; non-empty) in O(n).
/// Behaviour is undefined for characters other than '0'-'9'.
Magnitude from_digits(std::string_view digits);

/// Canonical decimal string ("0" for zero), O(n).
std::string to_string(const Magnitude& m);

/// Three-way compare: -1, 0 or 1.
int compare(const Magnitude& a, const Magnitude& b);

/// a + b, O(n + m).
Magnitude add(const Magnitude& a, const Magnitude& b);

/// a - b; requires a >= b. O(n + m).
Magnitude sub(const Magnitude& a, const Magnitude& b);

/// a * b by schoolbook multiplication, O(n * m).
Magnitude mul(const Magnitude& a, const Magnitude& b);

/// a * a, O(n^2) (about half the work of mul).
Magnitude square(const Magnitude& a);

struct DivMod {
    Magnitude quotient;
    Magnitude remainder;
};

/// Truncating division of a by b (b must be non-zero; throws
/// std::domain_error otherwise). Uses Knuth's Algorithm D, O((n-m+1) * m).
DivMod divmod(const Magnitude& a, const Magnitude& b);

/// a raised to the power e by binary exponentiation (a^0 == 1).
Magnitude pow(const Magnitude& a, std::uint64_t e);

}  // namespace bigint::mag
