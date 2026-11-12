// Package bigint implements signed arbitrary-precision integer arithmetic
// from scratch: addition, subtraction, multiplication, truncated division,
// remainder, exponentiation and comparison.
//
// Representation: an [Int] is a sign plus a magnitude stored as little-endian
// limbs in base 10^9. A decimal base makes parsing and printing linear in the
// number of digits. Multiplication is schoolbook (O(n·m)), division is Knuth's
// Algorithm D (O((n−m+1)·m)) and exponentiation is binary exponentiation.
//
// Values of type *Int are immutable: every operation returns a new value and
// never modifies its operands, so an *Int may be shared freely between
// goroutines. The zero value of Int is the number 0.
package bigint
