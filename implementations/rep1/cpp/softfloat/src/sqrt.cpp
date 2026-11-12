#include "round_pack.h"
#include "softfloat/softfloat.h"

namespace softfloat {

using namespace detail;

Bits32 sqrt(Bits32 a) {
  if (is_nan(a)) return kQuietNaN;
  if (is_zero(a)) return a;  // sqrt(+-0) = +-0
  if (sign_of(a)) return kQuietNaN;
  if (is_inf(a)) return a;

  Unpacked x = unpack_normalised(a);  // value = x.m * 2^(x.exp - 150), m in [2^23, 2^24)
  std::int32_t e = x.exp - 150;
  std::uint64_t m = x.m;
  if (e & 1) {  // make the exponent even
    m <<= 1;
    --e;
  }
  // m in [2^23, 2^25). Scale by 2^36 (even) so the root has 30-31 bits.
  const std::uint64_t radicand = m << 36;

  // Restoring digit-by-digit integer square root (two radicand bits per step).
  std::uint64_t rem = radicand, root = 0, bit = std::uint64_t{1} << 60;
  while (bit != 0) {
    if (rem >= root + bit) {
      rem -= root + bit;
      root = (root >> 1) + bit;
    } else {
      root >>= 1;
    }
    bit >>= 2;
  }
  // sqrt(value) = root * 2^(e/2 - 18) (+ sticky); shift once for the sticky bit.
  return round_pack(false, e / 2 - 19, (root << 1) | (rem != 0 ? 1 : 0));
}

}  // namespace softfloat
