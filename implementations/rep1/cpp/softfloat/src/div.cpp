#include "round_pack.h"
#include "softfloat/softfloat.h"

namespace softfloat {

using namespace detail;

Bits32 div(Bits32 a, Bits32 b) {
  if (is_nan(a) || is_nan(b)) return kQuietNaN;
  const bool sign = sign_of(a) != sign_of(b);
  if (is_inf(a)) return is_inf(b) ? kQuietNaN : infinity(sign);
  if (is_inf(b)) return zero(sign);
  if (is_zero(b)) return is_zero(a) ? kQuietNaN : infinity(sign);
  if (is_zero(a)) return zero(sign);

  const Unpacked x = unpack_normalised(a), y = unpack_normalised(b);
  // Both significands are in [2^23, 2^24), so (x.m << 40) fits in 64 bits and
  // the quotient has 40 or 41 bits: far more than the 24 + guard bits needed.
  const std::uint64_t num = x.m << 40;
  const std::uint64_t q = num / y.m;
  const bool inexact = (num % y.m) != 0;
  // x/y = q * 2^-40 * 2^(x.exp - y.exp); shift q left once to make room for the
  // sticky bit, which is applied before any denormal shift in round_pack.
  return round_pack(sign, x.exp - y.exp - 41, (q << 1) | (inexact ? 1 : 0));
}

}  // namespace softfloat
