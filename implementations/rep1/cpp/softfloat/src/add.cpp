#include <utility>

#include "round_pack.h"
#include "softfloat/softfloat.h"

namespace softfloat {

using namespace detail;

Bits32 add(Bits32 a, Bits32 b) {
  if (is_nan(a) || is_nan(b)) return kQuietNaN;
  const bool sa = sign_of(a), sb = sign_of(b);
  if (is_inf(a)) return (is_inf(b) && sa != sb) ? kQuietNaN : a;
  if (is_inf(b)) return b;
  if (is_zero(a)) return is_zero(b) ? zero(sa && sb) : b;
  if (is_zero(b)) return a;

  Unpacked x = unpack(a), y = unpack(b);
  // Make x the operand with the larger magnitude.
  if (x.exp < y.exp || (x.exp == y.exp && x.m < y.m)) std::swap(x, y);

  // 38 guard bits below the 24-bit significands; bits shifted out of the smaller
  // operand are folded into the sticky bit (bit 0). If more than one bit of
  // cancellation can happen (d <= 1), nothing has been shifted out, so it is exact.
  const std::uint64_t big = x.m << 38;
  const std::uint64_t small = shift_right_jam(y.m << 38, x.exp - y.exp);

  std::uint64_t sum;
  if (x.sign == y.sign) {
    sum = big + small;
  } else {
    sum = big - small;
    if (sum == 0) return zero(false);  // exact cancellation gives +0
  }
  // value = sum * 2^(x.exp - 150 - 38)
  return round_pack(x.sign, x.exp - 188, sum);
}

Bits32 sub(Bits32 a, Bits32 b) { return add(a, b ^ kSignMask); }

}  // namespace softfloat
