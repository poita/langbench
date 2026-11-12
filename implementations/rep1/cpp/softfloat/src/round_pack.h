// Internal: shared unpack / normalise / round-and-pack machinery.
#pragma once

#include <bit>
#include <cstdint>

#include "softfloat/bits.h"

namespace softfloat::detail {

/// Finite non-zero or zero operand as an integer significand and biased exponent:
/// value = m * 2^(exp - 150). Denormals use exp = 1 and no implicit bit.
struct Unpacked {
  bool sign;
  std::int32_t exp;
  std::uint64_t m;
};

constexpr Unpacked unpack(Bits32 x) {
  const std::uint32_t ef = exponent_field(x);
  const std::uint32_t f = fraction_field(x);
  if (ef == 0) return {sign_of(x), 1, f};
  return {sign_of(x), static_cast<std::int32_t>(ef), f | 0x00800000u};
}

/// Like unpack() for a non-zero finite value, but shifts the significand until
/// its top bit is bit 23 (decrementing exp, which may go below 1).
constexpr Unpacked unpack_normalised(Bits32 x) {
  Unpacked u = unpack(x);
  const int shift = std::countl_zero(static_cast<std::uint32_t>(u.m)) - 8;
  u.m <<= shift;
  u.exp -= shift;
  return u;
}

/// Shift right by n (any n >= 0), OR-ing everything shifted out into bit 0.
constexpr std::uint64_t shift_right_jam(std::uint64_t v, int n) {
  if (n <= 0) return v;
  if (n >= 64) return v != 0;
  return (v >> n) | ((v & ((std::uint64_t{1} << n) - 1)) != 0);
}

/// Round and pack the value sig * 2^e2 (sig != 0) with sign `sign`.
///
/// The single rounding step: round-to-nearest-even straight onto the binary32
/// grid, normal or denormal, with overflow to infinity.
///
/// `sig` may carry a "sticky" bit in its least significant bit (the OR of
/// discarded lower bits). Because sig is normalised by shifting left by up to
/// ~40 places, a sticky bit is only valid if sig has enough significant bits
/// that the sticky position stays below the rounding position (>= 26 bits).
Bits32 round_pack(bool sign, std::int32_t e2, std::uint64_t sig);

}  // namespace softfloat::detail
