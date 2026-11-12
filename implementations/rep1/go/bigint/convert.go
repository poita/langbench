package bigint

import "strings"

// parseNat parses a non-empty string of ASCII digits (leading zeros allowed).
func parseNat(s string) (nat, error) {
	if len(s) == 0 {
		return nil, ErrSyntax
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return nil, ErrSyntax
		}
	}
	z := make(nat, 0, (len(s)+baseDigits-1)/baseDigits)
	for end := len(s); end > 0; end -= baseDigits {
		start := end - baseDigits
		if start < 0 {
			start = 0
		}
		var limb uint32
		for _, c := range []byte(s[start:end]) {
			limb = limb*10 + uint32(c-'0')
		}
		z = append(z, limb)
	}
	return z.norm(), nil
}

// appendTo appends the canonical decimal digits of x to buf.
func (x nat) appendTo(buf []byte) []byte {
	if len(x) == 0 {
		return append(buf, '0')
	}
	top := x[len(x)-1]
	var tmp [baseDigits]byte
	i := len(tmp)
	for top != 0 {
		i--
		tmp[i] = byte('0' + top%10)
		top /= 10
	}
	buf = append(buf, tmp[i:]...)
	for k := len(x) - 2; k >= 0; k-- {
		l := x[k]
		for i := baseDigits - 1; i >= 0; i-- {
			tmp[i] = byte('0' + l%10)
			l /= 10
		}
		buf = append(buf, tmp[:]...)
	}
	return buf
}

// String returns the canonical decimal representation of x: no leading zeros,
// a leading '-' only for negative values, and "0" for zero.
func (x *Int) String() string {
	if x == nil {
		return "<nil>"
	}
	return string(x.Append(nil))
}

// Append appends the canonical decimal representation of x to buf and returns
// the extended buffer.
func (x *Int) Append(buf []byte) []byte {
	if x.neg {
		buf = append(buf, '-')
	}
	return x.mag.appendTo(buf)
}

// Parse converts a decimal integer of the form -?[0-9]+ to an Int. Leading
// zeros are accepted and "-0" (or "-000") denotes zero. Anything else,
// including an explicit '+' sign, yields ErrSyntax.
func Parse(s string) (*Int, error) {
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	mag, err := parseNat(s)
	if err != nil {
		return nil, err
	}
	return &Int{neg: neg && len(mag) > 0, mag: mag}, nil
}

// MustParse is like Parse but panics on error. It is intended for constants
// in tests and examples.
func MustParse(s string) *Int {
	x, err := Parse(s)
	if err != nil {
		panic(err)
	}
	return x
}
