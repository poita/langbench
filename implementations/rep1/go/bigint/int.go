package bigint

// Int is a signed arbitrary-precision integer. The zero value is 0. Values are
// immutable; all methods return new values. Methods accept a nil *Int as an
// operand only where documented; otherwise use the zero value.
type Int struct {
	neg bool // true only if the value is negative (never for zero)
	mag nat  // absolute value
}

// New returns an Int with the value x.
func New(x int64) *Int {
	if x < 0 {
		// -x overflows for MinInt64, but uint64(-x) wraps to the right value.
		return &Int{neg: true, mag: natFromUint64(uint64(-x))}
	}
	return &Int{mag: natFromUint64(uint64(x))}
}

// Sign returns -1, 0 or +1 according to whether x is negative, zero or
// positive.
func (x *Int) Sign() int {
	switch {
	case len(x.mag) == 0:
		return 0
	case x.neg:
		return -1
	}
	return 1
}

// Neg returns -x.
func (x *Int) Neg() *Int { return &Int{neg: !x.neg && len(x.mag) > 0, mag: x.mag} }

// Abs returns |x|.
func (x *Int) Abs() *Int { return &Int{mag: x.mag} }

// Cmp compares x and y and returns -1 if x < y, 0 if x == y and +1 if x > y.
func (x *Int) Cmp(y *Int) int {
	switch {
	case x.neg == y.neg:
		c := x.mag.cmp(y.mag)
		if x.neg {
			return -c
		}
		return c
	case x.neg:
		return -1
	}
	return 1
}

// Add returns x + y.
func (x *Int) Add(y *Int) *Int { return addSigned(x, y.mag, y.neg) }

// Sub returns x - y.
func (x *Int) Sub(y *Int) *Int { return addSigned(x, y.mag, !y.neg) }

// addSigned returns x + (±ym), where the sign of the second operand is yneg.
func addSigned(x *Int, ym nat, yneg bool) *Int {
	if x.neg == yneg {
		return &Int{neg: x.neg, mag: x.mag.add(ym)}
	}
	switch x.mag.cmp(ym) {
	case 0:
		return &Int{}
	case 1:
		return &Int{neg: x.neg, mag: x.mag.sub(ym)}
	}
	return &Int{neg: yneg, mag: ym.sub(x.mag)}
}

// Mul returns x * y.
func (x *Int) Mul(y *Int) *Int {
	m := x.mag.mul(y.mag)
	return &Int{neg: x.neg != y.neg && len(m) > 0, mag: m}
}

// QuoRem returns the quotient and remainder of x / y with C semantics: the
// quotient is truncated toward zero and the remainder has the sign of x (or is
// zero), so that x == q*y + r and |r| < |y|. It returns ErrDivisionByZero if y
// is zero.
func (x *Int) QuoRem(y *Int) (q, r *Int, err error) {
	if len(y.mag) == 0 {
		return nil, nil, ErrDivisionByZero
	}
	qm, rm := x.mag.divMod(y.mag)
	q = &Int{neg: x.neg != y.neg && len(qm) > 0, mag: qm}
	r = &Int{neg: x.neg && len(rm) > 0, mag: rm}
	return q, r, nil
}

// Quo returns the truncated quotient x / y, or ErrDivisionByZero.
func (x *Int) Quo(y *Int) (*Int, error) {
	q, _, err := x.QuoRem(y)
	return q, err
}

// Rem returns the remainder x % y (sign of x), or ErrDivisionByZero.
func (x *Int) Rem(y *Int) (*Int, error) {
	_, r, err := x.QuoRem(y)
	return r, err
}

// Exp returns x raised to the power y, with 0^0 == 1. It returns
// ErrNegativeExponent if y is negative, and ErrExponentTooLarge if y exceeds
// 64 bits and x is not 0, 1 or -1.
func (x *Int) Exp(y *Int) (*Int, error) {
	if y.neg {
		return nil, ErrNegativeExponent
	}
	if len(y.mag) == 0 {
		return New(1), nil
	}
	odd := y.mag[0]&1 == 1 // base 10^9 is even, so parity is the low limb's
	switch {
	case len(x.mag) == 0:
		return &Int{}, nil
	case len(x.mag) == 1 && x.mag[0] == 1: // x == ±1
		return &Int{neg: x.neg && odd, mag: nat{1}}, nil
	}
	e, ok := y.mag.uint64()
	if !ok {
		return nil, ErrExponentTooLarge
	}
	return &Int{neg: x.neg && odd, mag: x.mag.pow(e)}, nil
}
