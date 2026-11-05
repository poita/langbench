package bigint

import "errors"

var (
	// ErrDivisionByZero is returned by QuoRem, Quo and Rem when the divisor is zero.
	ErrDivisionByZero = errors.New("bigint: division by zero")
	// ErrNegativeExponent is returned by Pow when the exponent is negative.
	ErrNegativeExponent = errors.New("bigint: negative exponent")
	// ErrExponentTooLarge is returned by Pow when the exponent does not fit in
	// 64 bits and the base is not 0, 1 or -1 (the result could not be stored).
	ErrExponentTooLarge = errors.New("bigint: exponent too large")
	// ErrSyntax is returned by Parse for text that is not a decimal integer.
	ErrSyntax = errors.New("bigint: invalid decimal integer")
)
