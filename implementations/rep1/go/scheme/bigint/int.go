// Package bigint implements arbitrary-precision signed integers using only
// classical algorithms: schoolbook multiplication, Knuth's Algorithm D for
// division, and repeated division by a power of ten for decimal output.
//
// Values are immutable: every operation returns a new *Int and never modifies
// its operands. The zero value of Int is the number 0.
package bigint

import (
	"strings"
)

// Int is an arbitrary-precision signed integer.
type Int struct {
	neg bool
	mag nat
}

// New returns an Int with the value x.
func New(x int64) *Int {
	u := uint64(x)
	neg := x < 0
	if neg {
		u = -u
	}
	return &Int{neg: neg, mag: natFromUint64(u)}
}

func make_(neg bool, mag nat) *Int {
	mag = mag.norm()
	if len(mag) == 0 {
		neg = false
	}
	return &Int{neg: neg, mag: mag}
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

// Int64 returns x as an int64 and reports whether it fits.
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
	if u >= 1<<63 {
		return 0, false
	}
	return int64(u), true
}

// Neg returns -x.
func (x *Int) Neg() *Int { return make_(!x.neg, x.mag) }

// Cmp compares x and y and returns -1, 0 or +1.
func (x *Int) Cmp(y *Int) int {
	switch {
	case x.neg != y.neg:
		if x.neg {
			return -1
		}
		return 1
	case x.neg:
		return natCmp(y.mag, x.mag)
	}
	return natCmp(x.mag, y.mag)
}

// Add returns x + y.
func (x *Int) Add(y *Int) *Int {
	if x.neg == y.neg {
		return make_(x.neg, natAdd(x.mag, y.mag))
	}
	if natCmp(x.mag, y.mag) >= 0 {
		return make_(x.neg, natSub(x.mag, y.mag))
	}
	return make_(y.neg, natSub(y.mag, x.mag))
}

// Sub returns x - y.
func (x *Int) Sub(y *Int) *Int { return x.Add(y.Neg()) }

// Mul returns x * y.
func (x *Int) Mul(y *Int) *Int {
	return make_(x.neg != y.neg, natMul(x.mag, y.mag))
}

// QuoRem returns the quotient and remainder of x / y, truncated toward zero:
// x = q*y + r, |r| < |y|, and r has the sign of x. It panics if y is zero.
func (x *Int) QuoRem(y *Int) (q, r *Int) {
	qm, rm := natDiv(x.mag, y.mag)
	return make_(x.neg != y.neg, qm), make_(x.neg, rm)
}

const (
	chunkDigits = 9
	chunkBase   = 1000000000
)

// String returns the decimal representation of x. It performs repeated
// division by 10^9, so it runs in O(n^2) for an n-limb number.
func (x *Int) String() string {
	if len(x.mag) == 0 {
		return "0"
	}
	var chunks []uint32
	cur := append(nat(nil), x.mag...)
	for len(cur) > 0 {
		var r uint32
		cur, r = natDivW(cur, chunkBase)
		chunks = append(chunks, r)
	}
	var sb strings.Builder
	if x.neg {
		sb.WriteByte('-')
	}
	for i := len(chunks) - 1; i >= 0; i-- {
		var buf [chunkDigits]byte
		v := chunks[i]
		for j := chunkDigits - 1; j >= 0; j-- {
			buf[j] = byte('0' + v%10)
			v /= 10
		}
		s := string(buf[:])
		if i == len(chunks)-1 {
			s = strings.TrimLeft(s, "0")
		}
		sb.WriteString(s)
	}
	return sb.String()
}

// Parse converts a decimal string with an optional leading '+' or '-' sign
// followed by one or more ASCII digits. It reports false on any other input.
func Parse(s string) (*Int, bool) {
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
	var mag nat
	for len(s) > 0 {
		n := len(s) % chunkDigits
		if n == 0 {
			n = chunkDigits
		}
		var chunk, pow uint32 = 0, 1
		for i := 0; i < n; i++ {
			chunk = chunk*10 + uint32(s[i]-'0')
			pow *= 10
		}
		mag = natMulAddW(mag, pow, chunk)
		s = s[n:]
	}
	return make_(neg, mag), true
}
