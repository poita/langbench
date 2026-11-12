package bigint

import "errors"

var (
	// ErrDivisionByZero is returned by [Int.QuoRem], [Int.Quo] and [Int.Rem]
	// when the divisor is zero.
	ErrDivisionByZero = errors.New("bigint: division by zero")

	// ErrNegativeExponent is returned by [Int.Exp] when the exponent is
	// negative.
	ErrNegativeExponent = errors.New("bigint: negative exponent")

	// ErrExponentTooLarge is returned by [Int.Exp] when the exponent does not
	// fit in 64 bits and the base is not 0, 1 or -1 (the result could not be
	// represented in memory anyway).
	ErrExponentTooLarge = errors.New("bigint: exponent too large")

	// ErrSyntax is returned by [Parse] for text that is not an optionally
	// negated, non-empty string of ASCII digits.
	ErrSyntax = errors.New("bigint: invalid decimal integer")
)
