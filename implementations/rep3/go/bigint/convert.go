package bigint

import (
	"errors"
	"strconv"
)

// ErrSyntax is returned by Parse and ParseBytes for text that is not a
// decimal integer of the form -?[0-9]+.
var ErrSyntax = errors.New("bigint: invalid decimal integer")

// Parse converts a decimal integer of the form -?[0-9]+ to an Int. Leading
// zeros are allowed, and "-0" is zero.
func Parse(s string) (*Int, error) {
	return ParseBytes([]byte(s))
}

// ParseBytes is like Parse but takes a byte slice (which it does not retain).
// Its running time is linear in len(b).
func ParseBytes(b []byte) (*Int, error) {
	neg := false
	if len(b) > 0 && b[0] == '-' {
		neg = true
		b = b[1:]
	}
	if len(b) == 0 {
		return nil, ErrSyntax
	}
	for _, c := range b {
		if c < '0' || c > '9' {
			return nil, ErrSyntax
		}
	}
	return parseDigits(neg, b), nil
}

// parseDigits builds an Int from validated ASCII digits.
func parseDigits(neg bool, b []byte) *Int {
	for len(b) > 0 && b[0] == '0' {
		b = b[1:]
	}
	if len(b) == 0 {
		return &Int{}
	}
	z := make(nat, (len(b)+baseDigits-1)/baseDigits)
	for i := range z {
		lo := len(b) - baseDigits
		if lo < 0 {
			lo = 0
		}
		var limb uint32
		for _, c := range b[lo:] {
			limb = limb*10 + uint32(c-'0')
		}
		z[i] = limb
		b = b[:lo]
	}
	return &Int{neg: neg, abs: z}
}

// AppendTo appends the canonical decimal form of x to dst and returns the
// extended slice. It runs in time linear in the size of x.
func (x *Int) AppendTo(dst []byte) []byte {
	if len(x.abs) == 0 {
		return append(dst, '0')
	}
	if x.neg {
		dst = append(dst, '-')
	}
	n := len(x.abs)
	dst = strconv.AppendUint(dst, uint64(x.abs[n-1]), 10)
	for i := n - 2; i >= 0; i-- {
		v := x.abs[i]
		var buf [baseDigits]byte
		for k := baseDigits - 1; k >= 0; k-- {
			buf[k] = byte('0' + v%10)
			v /= 10
		}
		dst = append(dst, buf[:]...)
	}
	return dst
}

// String returns the canonical decimal form of x: no leading zeros, a leading
// '-' only for negative values, and "0" for zero.
func (x *Int) String() string {
	return string(x.AppendTo(nil))
}
