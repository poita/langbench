/**
 * Software IEEE-754 binary32 arithmetic.
 *
 * Addition, subtraction, multiplication, division and square root on raw
 * 32-bit patterns, with round-to-nearest-even and gradual underflow,
 * implemented purely with integer operations.
 *
 * ---
 * import softfloat;
 * assert(add(0x3f800000, 0x3f800000) == 0x40000000); // 1 + 1 = 2
 * assert(sqrt(0x40000000) == 0x3fb504f3);            // sqrt(2)
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `softfloat.bits`  - field masks, classification, unpacking)
 *   $(LI `softfloat.round` - the shared round-and-pack routine)
 *   $(LI `softfloat.arith` - add, sub, mul, div, sqrt)
 *   $(LI `softfloat.io`    - the line-oriented batch text format)
 * )
 */
module softfloat;

public import softfloat.bits;
public import softfloat.round;
public import softfloat.arith;
public import softfloat.io;
