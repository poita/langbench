package bigint

import (
	"errors"
	"strings"
)

// Errors returned by Int operations.
var (
	// ErrDivByZero is returned by Quo, Rem and QuoRem when the divisor is zero.
	ErrDivByZero = errors.New("bigint: division by zero")
	// ErrNegativeExponent is returned by Exp when the exponent is negative.
	ErrNegativeExponent = errors.New("bigint: negative exponent")
	// ErrExponentTooLarge is returned by Exp when the exponent does not fit
	// in a uint64 and the base is not 0, 1 or -1 (the result would be
	// astronomically large).
	ErrExponentTooLarge = errors.New("bigint: exponent too large")
	// ErrSyntax is returned by Parse for strings that are not of the form
	// -?[0-9]+.
	ErrSyntax = errors.New("bigint: invalid decimal integer")
)

// Int is a signed arbitrary-precision integer. The zero value is 0.
// Values are immutable; see the package documentation.
type Int struct {
	neg bool // never true when mag is zero
	mag nat
}

func newInt(neg bool, mag nat) *Int {
	return &Int{neg: neg && len(mag) > 0, mag: mag}
}

// FromInt64 returns an Int with the value v.
func FromInt64(v int64) *Int {
	if v < 0 {
		// Negate in unsigned arithmetic so that MinInt64 works.
		return newInt(true, natFromUint64(-uint64(v)))
	}
	return newInt(false, natFromUint64(uint64(v)))
}

// Parse converts a decimal string of the form -?[0-9]+ to an Int. Leading
// zeros and "negative zero" forms such as "-000" are accepted.
func Parse(s string) (*Int, error) {
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	if s == "" {
		return nil, ErrSyntax
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return nil, ErrSyntax
		}
	}
	s = strings.TrimLeft(s, "0")
	mag := make(nat, 0, (len(s)+baseDigits-1)/baseDigits)
	for end := len(s); end > 0; end -= baseDigits {
		start := end - baseDigits
		if start < 0 {
			start = 0
		}
		var limb uint32
		for _, c := range s[start:end] {
			limb = limb*10 + uint32(c-'0')
		}
		mag = append(mag, limb)
	}
	return newInt(neg, mag), nil
}

// MustParse is like Parse but panics on malformed input.
func MustParse(s string) *Int {
	z, err := Parse(s)
	if err != nil {
		panic(err)
	}
	return z
}

// String returns the canonical decimal form of x: no leading zeros and a
// leading '-' only for negative values.
func (x *Int) String() string {
	if len(x.mag) == 0 {
		return "0"
	}
	n := (len(x.mag)-1)*baseDigits + digitCount(x.mag[len(x.mag)-1])
	if x.neg {
		n++
	}
	buf := make([]byte, n)
	pos := n
	for _, limb := range x.mag[:len(x.mag)-1] {
		for k := 0; k < baseDigits; k++ {
			pos--
			buf[pos] = byte('0' + limb%10)
			limb /= 10
		}
	}
	for top := x.mag[len(x.mag)-1]; top > 0; top /= 10 {
		pos--
		buf[pos] = byte('0' + top%10)
	}
	if x.neg {
		buf[0] = '-'
	}
	return string(buf)
}

func digitCount(v uint32) int {
	n := 0
	for ; v > 0; v /= 10 {
		n++
	}
	return n
}

// Sign returns -1, 0 or +1 as x is negative, zero or positive.
func (x *Int) Sign() int {
	switch {
	case len(x.mag) == 0:
		return 0
	case x.neg:
		return -1
	}
	return 1
}

// Cmp returns -1, 0 or +1 as x <, == or > y.
func (x *Int) Cmp(y *Int) int {
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

// Neg returns -x.
func (x *Int) Neg() *Int { return newInt(!x.neg, x.mag) }

// Abs returns |x|.
func (x *Int) Abs() *Int { return newInt(false, x.mag) }

// Add returns x + y.
func (x *Int) Add(y *Int) *Int {
	if x.neg == y.neg {
		return newInt(x.neg, x.mag.add(y.mag))
	}
	return subSigned(x.neg, x.mag, y.mag)
}

// Sub returns x - y.
func (x *Int) Sub(y *Int) *Int {
	if x.neg != y.neg {
		return newInt(x.neg, x.mag.add(y.mag))
	}
	return subSigned(x.neg, x.mag, y.mag)
}

// subSigned returns (-1)^neg * (a - b) for magnitudes a and b.
func subSigned(neg bool, a, b nat) *Int {
	if a.cmp(b) >= 0 {
		return newInt(neg, a.sub(b))
	}
	return newInt(!neg, b.sub(a))
}

// Mul returns x * y.
func (x *Int) Mul(y *Int) *Int {
	return newInt(x.neg != y.neg, x.mag.mul(y.mag))
}

// QuoRem returns the quotient and remainder of x / y, truncated toward zero
// (C semantics): x == q*y + r, |r| < |y|, and r is zero or has the sign of x.
// It returns ErrDivByZero if y is zero.
func (x *Int) QuoRem(y *Int) (q, r *Int, err error) {
	if len(y.mag) == 0 {
		return nil, nil, ErrDivByZero
	}
	qm, rm := x.mag.divmod(y.mag)
	return newInt(x.neg != y.neg, qm), newInt(x.neg, rm), nil
}

// Quo returns x / y truncated toward zero, or ErrDivByZero.
func (x *Int) Quo(y *Int) (*Int, error) {
	q, _, err := x.QuoRem(y)
	return q, err
}

// Rem returns the remainder of x / y (sign of x), or ErrDivByZero.
func (x *Int) Rem(y *Int) (*Int, error) {
	_, r, err := x.QuoRem(y)
	return r, err
}

// Exp returns x**y. x**0 is 1 for every x, including 0. It returns
// ErrNegativeExponent if y < 0, and ErrExponentTooLarge if y does not fit in
// a uint64 and |x| > 1.
func (x *Int) Exp(y *Int) (*Int, error) {
	if y.neg {
		return nil, ErrNegativeExponent
	}
	e, ok := y.mag.uint64()
	if !ok {
		switch {
		case len(x.mag) == 0:
			return newInt(false, nil), nil
		case len(x.mag) == 1 && x.mag[0] == 1:
			odd := y.mag[0]%2 == 1 // base is even, so parity is the low limb's
			return newInt(x.neg && odd, x.mag), nil
		}
		return nil, ErrExponentTooLarge
	}
	return newInt(x.neg && e&1 == 1, x.mag.pow(e)), nil
}
