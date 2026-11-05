package bigint

import "errors"

// Errors returned by the arithmetic methods.
var (
	// ErrDivByZero is returned when dividing by zero.
	ErrDivByZero = errors.New("bigint: division by zero")
	// ErrNegativeExponent is returned by Exp for a negative exponent.
	ErrNegativeExponent = errors.New("bigint: negative exponent")
	// ErrExponentTooLarge is returned by Exp when the exponent does not fit
	// in 64 bits and the base is not 0, 1 or -1 (the result would be
	// astronomically large).
	ErrExponentTooLarge = errors.New("bigint: exponent too large")
)

// Int is an immutable signed arbitrary-precision integer. The zero value is 0.
// Methods never modify their receiver or arguments.
type Int struct {
	neg bool // true only for strictly negative values
	abs nat  // magnitude; empty for zero
}

// NewInt returns an Int with value v.
func NewInt(v int64) *Int {
	neg := v < 0
	u := uint64(v)
	if neg {
		u = -u // correct even for math.MinInt64
	}
	var z nat
	for u > 0 {
		z = append(z, uint32(u%base))
		u /= base
	}
	return &Int{neg: neg, abs: z}
}

// Sign returns -1, 0 or +1 according to the sign of x.
func (x *Int) Sign() int {
	switch {
	case len(x.abs) == 0:
		return 0
	case x.neg:
		return -1
	}
	return 1
}

// Neg returns -x. The magnitude is shared, not copied.
func (x *Int) Neg() *Int {
	return &Int{neg: !x.neg && len(x.abs) > 0, abs: x.abs}
}

// Abs returns |x|. The magnitude is shared, not copied.
func (x *Int) Abs() *Int {
	return &Int{abs: x.abs}
}

// Cmp returns -1, 0 or +1 as x is less than, equal to or greater than y.
func (x *Int) Cmp(y *Int) int {
	sx, sy := x.Sign(), y.Sign()
	switch {
	case sx != sy:
		if sx < sy {
			return -1
		}
		return 1
	case sx == 0:
		return 0
	case sx > 0:
		return cmpNat(x.abs, y.abs)
	}
	return cmpNat(y.abs, x.abs)
}

// Uint64 returns the value of x as a uint64 and reports whether x is
// non-negative and fits.
func (x *Int) Uint64() (uint64, bool) {
	if x.neg || len(x.abs) > 3 {
		return 0, false
	}
	var v uint64
	for i := len(x.abs) - 1; i >= 0; i-- {
		hi, lo := mulAdd(v, uint64(x.abs[i]))
		if hi {
			return 0, false
		}
		v = lo
	}
	return v, true
}

// mulAdd computes v*base + d, reporting overflow.
func mulAdd(v, d uint64) (overflow bool, r uint64) {
	const max = ^uint64(0)
	if v > (max-d)/base {
		return true, 0
	}
	return false, v*base + d
}

// addSigned returns x + (±y), where yNeg is the effective sign of y.
func addSigned(x *Int, yAbs nat, yNeg bool) *Int {
	if x.neg == yNeg {
		z := addNat(x.abs, yAbs)
		return &Int{neg: yNeg && len(z) > 0, abs: z}
	}
	switch cmpNat(x.abs, yAbs) {
	case 0:
		return &Int{}
	case 1:
		return &Int{neg: x.neg, abs: subNat(x.abs, yAbs)}
	}
	return &Int{neg: yNeg, abs: subNat(yAbs, x.abs)}
}

// Add returns x + y.
func (x *Int) Add(y *Int) *Int { return addSigned(x, y.abs, y.neg) }

// Sub returns x - y.
func (x *Int) Sub(y *Int) *Int { return addSigned(x, y.abs, !y.neg && len(y.abs) > 0) }

// Mul returns x * y.
func (x *Int) Mul(y *Int) *Int {
	z := mulNat(x.abs, y.abs)
	return &Int{neg: len(z) > 0 && x.neg != y.neg, abs: z}
}

// QuoRem returns the quotient q and remainder r of x / y, with q truncated
// toward zero and r having the sign of x (or being zero), so that
// x == q*y + r and |r| < |y|. It returns ErrDivByZero if y is zero.
func (x *Int) QuoRem(y *Int) (q, r *Int, err error) {
	if len(y.abs) == 0 {
		return nil, nil, ErrDivByZero
	}
	qa, ra := divNat(x.abs, y.abs)
	q = &Int{neg: len(qa) > 0 && x.neg != y.neg, abs: qa}
	r = &Int{neg: len(ra) > 0 && x.neg, abs: ra}
	return q, r, nil
}

// Quo returns the quotient x / y truncated toward zero, or ErrDivByZero.
func (x *Int) Quo(y *Int) (*Int, error) {
	q, _, err := x.QuoRem(y)
	return q, err
}

// Rem returns the remainder x % y, which has the sign of x, or ErrDivByZero.
func (x *Int) Rem(y *Int) (*Int, error) {
	_, r, err := x.QuoRem(y)
	return r, err
}

// Pow returns x raised to the power n. Pow(0, 0) is 1.
func (x *Int) Pow(n uint64) *Int {
	z := powNat(x.abs, n)
	return &Int{neg: len(z) > 0 && x.neg && n&1 == 1, abs: z}
}

// Exp returns x raised to the power y. It returns ErrNegativeExponent if
// y < 0 (zero is not negative). x**0 is 1 for every x, including 0.
func (x *Int) Exp(y *Int) (*Int, error) {
	if y.neg {
		return nil, ErrNegativeExponent
	}
	if len(y.abs) == 0 {
		return NewInt(1), nil
	}
	if n, ok := y.Uint64(); ok {
		return x.Pow(n), nil
	}
	// The exponent is huge: only 0 and ±1 have representable powers.
	switch {
	case len(x.abs) == 0:
		return &Int{}, nil
	case len(x.abs) == 1 && x.abs[0] == 1:
		odd := y.abs[0]&1 == 1 // base is even, so limb parity is value parity
		return &Int{neg: x.neg && odd, abs: x.abs}, nil
	}
	return nil, ErrExponentTooLarge
}
