// Package bigint implements signed arbitrary-precision integer arithmetic
// from scratch, without math/big.
//
// An Int is a sign and a magnitude. The magnitude is a little-endian slice of
// base-10⁹ limbs, so converting to and from decimal text is linear in the
// number of digits. Multiplication and division are the classical quadratic
// algorithms (schoolbook multiplication, Knuth's Algorithm D), which are
// plenty fast for numbers of a few tens of thousands of digits.
//
// Int values are immutable: every operation returns a new *Int and never
// modifies its arguments, so values may be shared freely (and between
// goroutines). The zero value of Int is the number zero, and is ready to use.
//
// Division follows C semantics: the quotient is truncated toward zero and the
// remainder takes the sign of the dividend.
package bigint
