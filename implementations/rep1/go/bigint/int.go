package bigint

import (
	"errors"
	"math/bits"
)

// Errors returned by Int operations.
var (
	// ErrDivideByZero is returned by Div, Rem and DivMod when the divisor is zero.
	ErrDivideByZero = errors.New("bigint: division by zero")
	// ErrNegativeExponent is returned by Exp when the exponent is negative.
	ErrNegativeExponent = errors.New("bigint: negative exponent")
	// ErrExponentTooLarge is returned by Exp when the exponent does not fit in
	// a uint64 and the base is not 0, 1 or -1 (the result could not be
	// represented in any memory).
	ErrExponentTooLarge = errors.New("bigint: exponent too large")
)

// An Int is an arbitrary-precision signed integer. The zero value is 0.
// Ints are immutable; all methods return new values.
type Int struct {
	neg bool // never true when mag is empty
	mag nat
}

// newInt builds an Int from a normalised magnitude, normalising the sign of zero.
func newInt(neg bool, mag nat) *Int {
	return &Int{neg: neg && len(mag) > 0, mag: mag}
}

// FromInt64 returns an Int with the value v.
func FromInt64(v int64) *Int {
	neg := v < 0
	u := uint64(v)
	if neg {
		u = -u // correct for math.MinInt64 as well
	}
	return fromUint64(neg, u)
}

// FromUint64 returns an Int with the value v.
func FromUint64(v uint64) *Int { return fromUint64(false, v) }

func fromUint64(neg bool, u uint64) *Int {
	var mag nat
	for ; u != 0; u /= base {
		mag = append(mag, limb(u%base))
	}
	return newInt(neg, mag)
}

// Sign returns -1, 0 or +1 according to the sign of x.
func (x *Int) Sign() int {
	switch {
	case len(x.mag) == 0:
		return 0
	case x.neg:
		return -1
	}
	return 1
}

// IsZero reports whether x is zero.
func (x *Int) IsZero() bool { return len(x.mag) == 0 }

// Neg returns -x.
func (x *Int) Neg() *Int { return newInt(!x.neg, x.mag) }

// Abs returns |x|.
func (x *Int) Abs() *Int { return newInt(false, x.mag) }

// Cmp compares x and y, returning -1 if x < y, 0 if x == y and +1 if x > y.
func (x *Int) Cmp(y *Int) int {
	sx, sy := x.Sign(), y.Sign()
	if sx != sy {
		if sx < sy {
			return -1
		}
		return 1
	}
	c := x.mag.cmp(y.mag)
	if sx < 0 {
		return -c
	}
	return c
}

// Add returns x + y.
func (x *Int) Add(y *Int) *Int { return addSigned(x, y, y.neg) }

// Sub returns x - y.
func (x *Int) Sub(y *Int) *Int { return addSigned(x, y, !y.neg) }

// addSigned returns x + (±|y|), where yneg is the sign to use for y.
func addSigned(x, y *Int, yneg bool) *Int {
	if x.neg == yneg {
		return newInt(x.neg, x.mag.add(y.mag))
	}
	switch x.mag.cmp(y.mag) {
	case 0:
		return &Int{}
	case 1:
		return newInt(x.neg, x.mag.sub(y.mag))
	}
	return newInt(yneg, y.mag.sub(x.mag))
}

// Mul returns x · y.
func (x *Int) Mul(y *Int) *Int {
	return newInt(x.neg != y.neg, x.mag.mul(y.mag))
}

// DivMod returns the quotient and remainder of x / y with C semantics: the
// quotient is truncated toward zero and the remainder has the sign of x (or is
// zero), so that x == q·y + r and |r| < |y|. It returns ErrDivideByZero if y
// is zero.
func (x *Int) DivMod(y *Int) (q, r *Int, err error) {
	if y.IsZero() {
		return nil, nil, ErrDivideByZero
	}
	qm, rm := x.mag.divMod(y.mag)
	return newInt(x.neg != y.neg, qm), newInt(x.neg, rm), nil
}

// Div returns the quotient x / y truncated toward zero, or ErrDivideByZero.
func (x *Int) Div(y *Int) (*Int, error) {
	q, _, err := x.DivMod(y)
	return q, err
}

// Rem returns the remainder of x / y, with the sign of x, or ErrDivideByZero.
func (x *Int) Rem(y *Int) (*Int, error) {
	_, r, err := x.DivMod(y)
	return r, err
}

// Exp returns x raised to the power y. It returns ErrNegativeExponent if y is
// negative. x^0 is 1 for every x, including 0.
func (x *Int) Exp(y *Int) (*Int, error) {
	if y.neg {
		return nil, ErrNegativeExponent
	}
	var e uint64
	for i := len(y.mag) - 1; i >= 0; i-- {
		hi, lo := bits.Mul64(e, base)
		lo, carry := bits.Add64(lo, uint64(y.mag[i]), 0)
		if hi != 0 || carry != 0 {
			// Only 0, 1 and -1 have a representable power.
			return x.expHuge(y)
		}
		e = lo
	}
	return x.ExpUint64(e), nil
}

// expHuge handles exponents that do not fit in a uint64.
func (x *Int) expHuge(y *Int) (*Int, error) {
	if len(x.mag) == 0 {
		return &Int{}, nil
	}
	if len(x.mag) == 1 && x.mag[0] == 1 {
		return newInt(x.neg && y.mag[0]&1 == 1, x.mag), nil
	}
	return nil, ErrExponentTooLarge
}

// ExpUint64 returns x raised to the power e.
func (x *Int) ExpUint64(e uint64) *Int {
	return newInt(x.neg && e&1 == 1, x.mag.pow(e))
}
