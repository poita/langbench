// Package bigint implements signed arbitrary-precision integer arithmetic
// from scratch, without math/big.
//
// An Int is a sign and a magnitude. The magnitude is a little-endian slice of
// base-10⁹ limbs, so parsing and printing decimal text are linear in the
// number of digits. Arithmetic uses classical quadratic algorithms:
// schoolbook multiplication, Knuth's Algorithm D for long division and
// left-to-right binary exponentiation.
//
// Int values are immutable: every operation returns a new Int and never
// modifies its operands, and the zero value is the integer 0. Operations may
// share limb storage between values, which is safe precisely because limbs are
// never mutated after construction.
//
// Division follows C semantics: the quotient truncates toward zero and the
// remainder has the sign of the dividend.
package bigint
