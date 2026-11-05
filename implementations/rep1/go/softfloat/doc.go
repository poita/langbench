// Package softfloat implements IEEE-754 binary32 (single-precision) addition,
// subtraction, multiplication, division and square root in software, using
// only integer arithmetic.
//
// Values are exchanged as raw 32-bit patterns (uint32). Every operation rounds
// the exact mathematical result once, to nearest with ties to even, and
// supports gradual underflow (denormals) and overflow to infinity. Floating
// point exceptions and flags are not modelled.
//
// NaN handling is deliberately simple: any NaN operand, and every invalid
// operation, yields the canonical quiet NaN [QNaN] (0x7fc00000); payloads and
// signs of NaNs are never propagated.
//
// No hardware floating point, math.Sqrt, or conversions are used anywhere in
// the package; all significand work happens in a single unsigned 64-bit word
// plus a sticky flag.
package softfloat
