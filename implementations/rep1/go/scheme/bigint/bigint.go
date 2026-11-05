// Package bigint implements arbitrary-precision signed integers from scratch.
//
// Numbers are stored as a sign plus a little-endian magnitude of 32-bit limbs
// with no high zero limbs; every limb operation uses 64-bit intermediates.
// Multiplication is schoolbook, division is Knuth's Algorithm D (with a
// short-division fast path for one-limb divisors), and decimal conversion
// works in chunks of 10^9. Values are immutable: every operation returns a
// new *Int and never modifies its operands.
package bigint

import (
	"math/bits"
)

// Int is an immutable arbitrary-precision signed integer. The zero value is
// not usable as a number; obtain Ints from FromInt64, Parse or arithmetic.
type Int struct {
	neg bool
	mag []uint32 // little-endian, no high zero limbs; empty means zero
}

const chunk = 1000000000 // 10^9, the largest power of ten below 2^32

// FromInt64 returns v as an Int.
func FromInt64(v int64) *Int {
	if v == 0 {
		return &Int{}
	}
	neg := v < 0
	var u uint64
	if neg {
		u = -uint64(v) // correct for math.MinInt64 as well
	} else {
		u = uint64(v)
	}
	return fromUint64(neg, u)
}

func fromUint64(neg bool, u uint64) *Int {
	if u == 0 {
		return &Int{}
	}
	if u>>32 == 0 {
		return &Int{neg: neg, mag: []uint32{uint32(u)}}
	}
	return &Int{neg: neg, mag: []uint32{uint32(u), uint32(u >> 32)}}
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

// Int64 returns x as an int64 and true if it fits, or (0, false) otherwise.
func (x *Int) Int64() (int64, bool) {
	if len(x.mag) > 2 {
		return 0, false
	}
	var u uint64
	for i := len(x.mag) - 1; i >= 0; i-- {
		u = u<<32 | uint64(x.mag[i])
	}
	if x.neg {
		if u > 1<<63 {
			return 0, false
		}
		return int64(-u), true
	}
	if u > 1<<63-1 {
		return 0, false
	}
	return int64(u), true
}

// Neg returns -x.
func (x *Int) Neg() *Int {
	if len(x.mag) == 0 {
		return x
	}
	return &Int{neg: !x.neg, mag: x.mag}
}

// Cmp compares x and y and returns -1, 0 or +1.
func (x *Int) Cmp(y *Int) int {
	if x.neg != y.neg { // zero is never negative, so this is unambiguous
		if x.neg {
			return -1
		}
		return 1
	}
	c := cmpMag(x.mag, y.mag)
	if x.neg {
		return -c
	}
	return c
}

// Add returns x + y.
func (x *Int) Add(y *Int) *Int {
	if x.neg == y.neg {
		return &Int{neg: x.neg, mag: addMag(x.mag, y.mag)}
	}
	return signedDiff(x, y)
}

// Sub returns x - y.
func (x *Int) Sub(y *Int) *Int {
	if x.neg != y.neg {
		return &Int{neg: x.neg, mag: addMag(x.mag, y.mag)}
	}
	return signedDiff(x, y)
}

// signedDiff computes the sum of x and -y' where x and y have the same sign
// field (Sub) or opposite ones (Add): in both cases the result is the
// difference of magnitudes with the sign of whichever is larger.
func signedDiff(x, y *Int) *Int {
	switch cmpMag(x.mag, y.mag) {
	case 0:
		return &Int{}
	case 1:
		return &Int{neg: x.neg, mag: subMag(x.mag, y.mag)}
	}
	// |x| < |y|: result takes the sign opposite to y's role. For Add (x.neg
	// != y.neg) that is y.neg; for Sub (x.neg == y.neg) that is !y.neg.
	return &Int{neg: !x.neg, mag: subMag(y.mag, x.mag)}
}

func (x *Int) norm() *Int {
	if len(x.mag) == 0 {
		x.neg = false
	}
	return x
}

// Mul returns x * y.
func (x *Int) Mul(y *Int) *Int {
	if len(x.mag) == 0 || len(y.mag) == 0 {
		return &Int{}
	}
	return &Int{neg: x.neg != y.neg, mag: mulMag(x.mag, y.mag)}
}

// QuoRem returns the quotient and remainder of x / y, truncated toward zero:
// x = q*y + r with |r| < |y| and r having the sign of x (or being zero).
// It returns ok == false, and nil results, if y is zero.
func (x *Int) QuoRem(y *Int) (q, r *Int, ok bool) {
	if len(y.mag) == 0 {
		return nil, nil, false
	}
	var qm, rm []uint32
	switch {
	case cmpMag(x.mag, y.mag) < 0:
		rm = x.mag
	case len(y.mag) == 1:
		var rs uint32
		qm, rs = divSmall(x.mag, y.mag[0])
		if rs != 0 {
			rm = []uint32{rs}
		}
	default:
		qm, rm = divMag(x.mag, y.mag)
	}
	q = (&Int{neg: x.neg != y.neg, mag: qm}).norm()
	r = (&Int{neg: x.neg, mag: rm}).norm()
	return q, r, true
}

// String returns the decimal representation of x.
func (x *Int) String() string {
	if len(x.mag) == 0 {
		return "0"
	}
	// Peel off base-10^9 groups with short division on a scratch copy.
	scratch := append([]uint32(nil), x.mag...)
	groups := make([]uint32, 0, len(scratch)*32/29+1)
	for len(scratch) > 0 {
		var rem uint32
		scratch, rem = divSmallInPlace(scratch, chunk)
		groups = append(groups, rem)
	}
	buf := make([]byte, 0, len(groups)*9+1)
	if x.neg {
		buf = append(buf, '-')
	}
	for i := len(groups) - 1; i >= 0; i-- {
		g := groups[i]
		var digits [9]byte
		for j := 8; j >= 0; j-- {
			digits[j] = byte('0' + g%10)
			g /= 10
		}
		if i == len(groups)-1 {
			k := 0
			for k < 8 && digits[k] == '0' {
				k++
			}
			buf = append(buf, digits[k:]...)
		} else {
			buf = append(buf, digits[:]...)
		}
	}
	return string(buf)
}

// Parse converts an optionally signed string of decimal digits to an Int. It
// returns ok == false if s is not of the form [+-]?[0-9]+.
func Parse(s string) (z *Int, ok bool) {
	neg := false
	if len(s) > 0 && (s[0] == '+' || s[0] == '-') {
		neg = s[0] == '-'
		s = s[1:]
	}
	if len(s) == 0 {
		return nil, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return nil, false
		}
	}
	mag := make([]uint32, 0, len(s)/9+1)
	first := len(s) % 9
	if first == 0 {
		first = 9
	}
	for pos := 0; pos < len(s); {
		n := 9
		if pos == 0 {
			n = first
		}
		var c uint32
		for _, d := range []byte(s[pos : pos+n]) {
			c = c*10 + uint32(d-'0')
		}
		mag = mulAddSmall(mag, chunk, c)
		pos += n
	}
	return (&Int{neg: neg, mag: mag}).norm(), true
}

// ---- magnitude helpers (little-endian []uint32, normalised) ----

func trim(m []uint32) []uint32 {
	for len(m) > 0 && m[len(m)-1] == 0 {
		m = m[:len(m)-1]
	}
	return m
}

func cmpMag(a, b []uint32) int {
	if len(a) != len(b) {
		if len(a) < len(b) {
			return -1
		}
		return 1
	}
	for i := len(a) - 1; i >= 0; i-- {
		if a[i] != b[i] {
			if a[i] < b[i] {
				return -1
			}
			return 1
		}
	}
	return 0
}

func addMag(a, b []uint32) []uint32 {
	if len(a) < len(b) {
		a, b = b, a
	}
	res := make([]uint32, len(a)+1)
	var carry uint64
	for i := range a {
		s := uint64(a[i]) + carry
		if i < len(b) {
			s += uint64(b[i])
		}
		res[i] = uint32(s)
		carry = s >> 32
	}
	res[len(a)] = uint32(carry)
	return trim(res)
}

// subMag returns a - b for |a| >= |b|.
func subMag(a, b []uint32) []uint32 {
	res := make([]uint32, len(a))
	var borrow uint64
	for i := range a {
		d := uint64(a[i]) - borrow
		if i < len(b) {
			d -= uint64(b[i])
		}
		res[i] = uint32(d)
		borrow = (d >> 32) & 1
	}
	return trim(res)
}

func mulMag(a, b []uint32) []uint32 {
	res := make([]uint32, len(a)+len(b))
	for i, ai := range a {
		if ai == 0 {
			continue
		}
		var carry uint64
		for j, bj := range b {
			cur := uint64(res[i+j]) + uint64(ai)*uint64(bj) + carry
			res[i+j] = uint32(cur)
			carry = cur >> 32
		}
		res[i+len(b)] = uint32(carry)
	}
	return trim(res)
}

// mulAddSmall returns m*mul + add, reusing m's storage when possible.
func mulAddSmall(m []uint32, mul, add uint32) []uint32 {
	carry := uint64(add)
	for i := range m {
		cur := uint64(m[i])*uint64(mul) + carry
		m[i] = uint32(cur)
		carry = cur >> 32
	}
	if carry != 0 {
		m = append(m, uint32(carry))
	}
	return m
}

// divSmall returns the quotient and remainder of a / d for a one-limb d.
func divSmall(a []uint32, d uint32) ([]uint32, uint32) {
	q := make([]uint32, len(a))
	var rem uint64
	for i := len(a) - 1; i >= 0; i-- {
		cur := rem<<32 | uint64(a[i])
		q[i] = uint32(cur / uint64(d))
		rem = cur % uint64(d)
	}
	return trim(q), uint32(rem)
}

// divSmallInPlace divides a by d, overwriting a with the quotient.
func divSmallInPlace(a []uint32, d uint32) ([]uint32, uint32) {
	var rem uint64
	for i := len(a) - 1; i >= 0; i-- {
		cur := rem<<32 | uint64(a[i])
		a[i] = uint32(cur / uint64(d))
		rem = cur % uint64(d)
	}
	return trim(a), uint32(rem)
}

// divMag implements Knuth's Algorithm D. It requires len(v) >= 2 and
// |u| >= |v| and returns the quotient and remainder magnitudes.
func divMag(u, v []uint32) (q, r []uint32) {
	n, m := len(v), len(u)-len(v)
	s := uint(bits.LeadingZeros32(v[n-1]))

	vn := make([]uint32, n)
	for i := n - 1; i > 0; i-- {
		vn[i] = v[i]<<s | uint32(uint64(v[i-1])>>(32-s))
	}
	vn[0] = v[0] << s
	un := make([]uint32, len(u)+1)
	un[len(u)] = uint32(uint64(u[len(u)-1]) >> (32 - s))
	for i := len(u) - 1; i > 0; i-- {
		un[i] = u[i]<<s | uint32(uint64(u[i-1])>>(32-s))
	}
	un[0] = u[0] << s

	q = make([]uint32, m+1)
	top, second := uint64(vn[n-1]), uint64(vn[n-2])
	for j := m; j >= 0; j-- {
		num := uint64(un[j+n])<<32 | uint64(un[j+n-1])
		qhat, rhat := num/top, num%top
		for qhat>>32 != 0 || qhat*second > rhat<<32|uint64(un[j+n-2]) {
			qhat--
			rhat += top
			if rhat>>32 != 0 {
				break
			}
		}
		// Multiply and subtract qhat*vn from un[j : j+n+1].
		var borrow int64
		var carry uint64
		for i := 0; i < n; i++ {
			p := qhat*uint64(vn[i]) + carry
			carry = p >> 32
			t := int64(un[i+j]) - borrow - int64(p&0xffffffff)
			un[i+j] = uint32(t)
			borrow = int64(uint64(t) >> 63)
		}
		t := int64(un[j+n]) - borrow - int64(carry)
		un[j+n] = uint32(t)
		if t < 0 {
			// qhat was one too large: add the divisor back.
			qhat--
			var c uint64
			for i := 0; i < n; i++ {
				sum := uint64(un[i+j]) + uint64(vn[i]) + c
				un[i+j] = uint32(sum)
				c = sum >> 32
			}
			un[j+n] += uint32(c)
		}
		q[j] = uint32(qhat)
	}

	r = make([]uint32, n)
	for i := 0; i < n-1; i++ {
		r[i] = un[i]>>s | uint32(uint64(un[i+1])<<(32-s))
	}
	r[n-1] = un[n-1] >> s
	return trim(q), trim(r)
}
