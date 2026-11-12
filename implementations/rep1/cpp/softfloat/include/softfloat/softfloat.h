// softfloat: IEEE-754 binary32 arithmetic using integer operations only.
//
// All functions take and return raw binary32 bit patterns and implement
// round-to-nearest-even with full gradual underflow. Any NaN operand, and
// every invalid operation, yields the canonical quiet NaN 0x7fc00000.
// Exception flags are not modelled. All functions are pure and thread-safe.
#pragma once

#include "softfloat/bits.h"

namespace softfloat {

/// a + b
Bits32 add(Bits32 a, Bits32 b);
/// a - b (identical to add(a, -b))
Bits32 sub(Bits32 a, Bits32 b);
/// a * b
Bits32 mul(Bits32 a, Bits32 b);
/// a / b
Bits32 div(Bits32 a, Bits32 b);
/// sqrt(a); NaN for a < 0 (including -inf), sqrt(-0) = -0.
Bits32 sqrt(Bits32 a);

}  // namespace softfloat
