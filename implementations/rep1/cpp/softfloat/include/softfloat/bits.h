// Bit-level helpers for IEEE-754 binary32 values held as raw uint32_t patterns.
#pragma once

#include <cstdint>

namespace softfloat {

/// A binary32 value, represented by its raw 32-bit pattern.
using Bits32 = std::uint32_t;

inline constexpr Bits32 kSignMask = 0x80000000u;
inline constexpr Bits32 kExpMask = 0x7f800000u;
inline constexpr Bits32 kFracMask = 0x007fffffu;
inline constexpr Bits32 kPositiveInfinity = 0x7f800000u;
inline constexpr Bits32 kNegativeInfinity = 0xff800000u;
/// The only NaN pattern the library ever produces.
inline constexpr Bits32 kQuietNaN = 0x7fc00000u;

constexpr bool sign_of(Bits32 x) { return (x & kSignMask) != 0; }
constexpr std::uint32_t exponent_field(Bits32 x) { return (x >> 23) & 0xffu; }
constexpr std::uint32_t fraction_field(Bits32 x) { return x & kFracMask; }

constexpr bool is_nan(Bits32 x) { return (x & kExpMask) == kExpMask && (x & kFracMask) != 0; }
constexpr bool is_inf(Bits32 x) { return (x & ~kSignMask) == kExpMask; }
constexpr bool is_zero(Bits32 x) { return (x & ~kSignMask) == 0; }

/// Build a pattern from its three fields (no range checking beyond masking).
constexpr Bits32 pack(bool sign, std::uint32_t exponent, std::uint32_t fraction) {
  return (sign ? kSignMask : 0u) | ((exponent & 0xffu) << 23) | (fraction & kFracMask);
}
constexpr Bits32 infinity(bool sign) { return sign ? kNegativeInfinity : kPositiveInfinity; }
constexpr Bits32 zero(bool sign) { return sign ? kSignMask : 0u; }

}  // namespace softfloat
