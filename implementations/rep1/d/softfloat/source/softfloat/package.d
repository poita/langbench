/**
 * Software IEEE-754 binary32 arithmetic on raw bit patterns.
 *
 * `softfloat` implements addition, subtraction, multiplication, division and
 * square root with round-to-nearest-even and full gradual underflow, using
 * only integer arithmetic.  Operands and results are `uint` bit patterns, so
 * every bit of a result is well-defined and checkable.
 *
 * $(UL
 *   $(LI `softfloat.bits`: field access, classification, unpacking)
 *   $(LI `softfloat.rounding`: the shared round-and-pack step)
 *   $(LI `softfloat.addsub`, `softfloat.mul`, `softfloat.div`,
 *        `softfloat.sqrt`: the operations)
 *   $(LI `softfloat.ops`: the `Float32` value type with operators)
 *   $(LI `softfloat.text`: the line-oriented hex text protocol)
 * )
 *
 * Importing `softfloat` pulls in all of them.  Because `div` and `sqrt`
 * would clash with identically named symbols in `std.math` and `std.algorithm`,
 * import selectively or use qualified names when mixing.
 *
 * Example:
 * ---
 * import softfloat;
 *
 * assert(softfloat.addsub.add(0x3f80_0000, 0x3f80_0000) == 0x4000_0000); // 1 + 1 = 2
 * assert(softfloat.div.div(0x3f80_0000, 0x4040_0000) == 0x3eaa_aaab);    // 1 / 3
 *
 * auto x = Float32(0x4000_0000);          // 2.0
 * assert(x.sqrt.bits == 0x3fb5_04f3);     // sqrt(2)
 * ---
 */
module softfloat;

public import softfloat.addsub;
public import softfloat.bits;
public import softfloat.div;
public import softfloat.mul;
public import softfloat.ops;
public import softfloat.rounding;
public import softfloat.sqrt;
public import softfloat.text;
version (unittest) import softfloat.tests;

unittest
{
    assert(softfloat.addsub.add(0x3f80_0000, 0x3f80_0000) == 0x4000_0000);
    assert(softfloat.div.div(0x3f80_0000, 0x4040_0000) == 0x3eaa_aaab);
    assert(Float32(0x4000_0000).sqrt.bits == 0x3fb5_04f3);
}
