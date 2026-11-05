package bigint

import "math/bits"

// Int is a signed arbitrary-precision integer. The zero value is 0.
// Ints are immutable and safe for concurrent use.
type Int struct {
	neg bool // never true for zero
	mag nat
}

func makeInt(neg bool, mag nat) Int {
	if len(mag) == 0 {
		neg = false
	}
	return Int{neg, mag}
}

// FromInt64 returns v as an Int.
func FromInt64(v int64) Int {
	if v < 0 {
		// -v overflows for MinInt64 but the uint64 conversion is exact.
		return makeInt(true, natFromUint64(uint64(-(v+1))+1))
	}
	return makeInt(false, natFromUint64(uint64(v)))
}

// FromUint64 returns v as an Int.
func FromUint64(v uint64) Int { return makeInt(false, natFromUint64(v)) }

// Sign returns -1, 0 or 1 according to the sign of x.
func (x Int) Sign() int {
	switch {
	case len(x.mag) == 0:
		return 0
	case x.neg:
		return -1
	}
	return 1
}

// IsZero reports whether x is zero.
func (x Int) IsZero() bool { return len(x.mag) == 0 }

// Neg returns -x. The magnitude is shared, not copied.
func (x Int) Neg() Int { return makeInt(!x.neg, x.mag) }

// Abs returns |x|.
func (x Int) Abs() Int { return Int{false, x.mag} }

// Cmp compares x and y, returning -1 if x < y, 0 if x == y and 1 if x > y.
func (x Int) Cmp(y Int) int {
	switch {
	case x.neg != y.neg:
		if x.neg {
			return -1
		}
		return 1
	case x.neg:
		return y.mag.cmp(x.mag)
	}
	return x.mag.cmp(y.mag)
}

// Add returns x + y.
func (x Int) Add(y Int) Int {
	if x.neg == y.neg {
		return makeInt(x.neg, x.mag.add(y.mag))
	}
	switch x.mag.cmp(y.mag) {
	case 0:
		return Int{}
	case 1:
		return makeInt(x.neg, x.mag.sub(y.mag))
	}
	return makeInt(y.neg, y.mag.sub(x.mag))
}

// Sub returns x - y.
func (x Int) Sub(y Int) Int { return x.Add(y.Neg()) }

// Mul returns x * y.
func (x Int) Mul(y Int) Int {
	return makeInt(x.neg != y.neg, x.mag.mul(y.mag))
}

// QuoRem returns the quotient and remainder of x / y with C semantics: the
// quotient is truncated toward zero and the remainder has the sign of x, so
// x == q*y + r and |r| < |y|. It returns ErrDivisionByZero if y is zero.
func (x Int) QuoRem(y Int) (q, r Int, err error) {
	if y.IsZero() {
		return Int{}, Int{}, ErrDivisionByZero
	}
	qm, rm := x.mag.divMod(y.mag)
	return makeInt(x.neg != y.neg, qm), makeInt(x.neg, rm), nil
}

// Quo returns x / y truncated toward zero, or ErrDivisionByZero.
func (x Int) Quo(y Int) (Int, error) {
	q, _, err := x.QuoRem(y)
	return q, err
}

// Rem returns the remainder of x / y with the sign of x, or ErrDivisionByZero.
func (x Int) Rem(y Int) (Int, error) {
	_, r, err := x.QuoRem(y)
	return r, err
}

// Pow returns x raised to the power y using left-to-right binary
// exponentiation. x^0 is 1 for every x, including 0. It returns
// ErrNegativeExponent if y < 0, and ErrExponentTooLarge if y does not fit in
// 64 bits and x is not 0, 1 or -1.
func (x Int) Pow(y Int) (Int, error) {
	if y.neg {
		return Int{}, ErrNegativeExponent
	}
	if y.IsZero() {
		return FromInt64(1), nil
	}
	odd := y.mag[0]&1 == 1
	switch {
	case x.IsZero():
		return Int{}, nil
	case len(x.mag) == 1 && x.mag[0] == 1:
		return makeInt(x.neg && odd, x.mag), nil
	}
	var e uint64
	for i := len(y.mag) - 1; i >= 0; i-- {
		hi, lo := bits.Mul64(e, base)
		sum, carry := bits.Add64(lo, uint64(y.mag[i]), 0)
		if hi != 0 || carry != 0 {
			return Int{}, ErrExponentTooLarge
		}
		e = sum
	}
	acc := x.mag
	for bit := bits.Len64(e) - 2; bit >= 0; bit-- {
		acc = acc.mul(acc)
		if e>>uint(bit)&1 == 1 {
			acc = acc.mul(x.mag)
		}
	}
	return makeInt(x.neg && odd, acc), nil
}
