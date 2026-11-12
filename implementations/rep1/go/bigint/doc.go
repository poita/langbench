// Package bigint implements signed arbitrary-precision integer arithmetic
// from scratch, without math/big.
//
// An [Int] is stored as a sign and a magnitude. The magnitude is a
// little-endian slice of 32-bit limbs in base 10^9, so converting to and from
// decimal text is linear in the number of digits. The algorithms are the
// classical ones:
//
//   - addition, subtraction and comparison: linear;
//   - multiplication: schoolbook, O(n·m);
//   - division: Knuth's Algorithm D, O((n−m+1)·m), producing quotient and
//     remainder together;
//   - exponentiation: binary exponentiation (repeated squaring).
//
// Values of type *Int are immutable: every operation returns a fresh *Int and
// never modifies its operands, so they may be shared freely between
// goroutines. The zero value of Int is a valid zero.
//
// Division follows C semantics: the quotient is truncated toward zero and the
// remainder has the sign of the dividend.
package bigint
