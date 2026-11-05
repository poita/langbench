// Package bigint implements signed arbitrary-precision integer arithmetic
// from scratch, using only fixed-size machine integers.
//
// An [Int] is a sign plus a magnitude. The magnitude is a little-endian slice
// of base-10⁹ limbs stored in uint32 elements, so parsing and printing decimal
// text are linear in the number of digits. Arithmetic uses the classical
// quadratic algorithms: linear addition, subtraction and comparison,
// schoolbook multiplication, Knuth's Algorithm D for long division and
// left-to-right binary exponentiation.
//
// Values of type [Int] are immutable: every operation returns a new *Int and
// never modifies its operands, so values may be freely shared between
// goroutines. The zero value of Int is the number 0.
package bigint
