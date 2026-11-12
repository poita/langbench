#include "round_pack.h"

namespace softfloat::detail {

Bits32 round_pack(bool sign, std::int32_t e2, std::uint64_t sig) {
  // Normalise so the leading one is bit 62; then sig's top 24 bits (62..39)
  // are the binary32 significand and bits 38..0 are guard/round/sticky.
  const int lz = std::countl_zero(sig);
  if (lz == 0) {
    sig = shift_right_jam(sig, 1);
    e2 += 1;
  } else if (lz > 1) {
    sig <<= lz - 1;
    e2 -= lz - 1;
  }
  // Biased exponent of the leading bit: value in [2^(e2+62), 2^(e2+63)).
  const std::int32_t biased = e2 + 62 + 127;
  if (biased >= 255) return infinity(sign);

  int shift = 39;
  if (biased < 1) shift += 1 - biased;  // denormal: fewer significand bits kept

  std::uint64_t q = 0;
  if (shift < 64) {
    q = sig >> shift;
    const std::uint64_t half = std::uint64_t{1} << (shift - 1);
    const std::uint64_t rem = sig & ((half << 1) - 1);
    if (rem > half || (rem == half && (q & 1))) ++q;
  }
  // else: below half of the smallest denormal even before rounding -> zero.

  // For normals q has the implicit bit (bit 23), so adding (biased-1)<<23 sets
  // the exponent field; a rounding carry bumps the exponent (up to infinity).
  // For denormals q is the fraction itself, and q == 2^23 is 0x00800000.
  const std::uint64_t base = biased >= 1 ? static_cast<std::uint64_t>(biased - 1) << 23 : 0;
  const std::uint64_t bits = base + q;
  if (bits >= kExpMask) return infinity(sign);
  return (sign ? kSignMask : 0u) | static_cast<Bits32>(bits);
}

}  // namespace softfloat::detail
