#include "round_pack.h"
#include "softfloat/softfloat.h"

namespace softfloat {

using namespace detail;

Bits32 mul(Bits32 a, Bits32 b) {
  if (is_nan(a) || is_nan(b)) return kQuietNaN;
  const bool sign = sign_of(a) != sign_of(b);
  if (is_inf(a) || is_inf(b)) return (is_zero(a) || is_zero(b)) ? kQuietNaN : infinity(sign);
  if (is_zero(a) || is_zero(b)) return zero(sign);

  const Unpacked x = unpack(a), y = unpack(b);
  // Exact 48-bit product; round_pack normalises it.
  return round_pack(sign, x.exp + y.exp - 300, x.m * y.m);
}

}  // namespace softfloat
