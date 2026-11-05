package bigint

import "fmt"

// ParseError describes a string that is not a valid decimal integer.
type ParseError struct {
	Input string
}

func (e *ParseError) Error() string {
	in := e.Input
	if len(in) > 20 {
		in = in[:20] + "..."
	}
	return fmt.Sprintf("bigint: invalid decimal integer %q", in)
}

// Parse converts a decimal string of the form -?[0-9]+ to an Int. Leading
// zeros are accepted and "-0" is zero. Parsing is linear in the length of s.
func Parse(s string) (*Int, error) { return ParseBytes([]byte(s)) }

// ParseBytes is like Parse but takes a byte slice (which it does not retain).
func ParseBytes(b []byte) (*Int, error) {
	neg := false
	digits := b
	if len(digits) > 0 && digits[0] == '-' {
		neg = true
		digits = digits[1:]
	}
	if len(digits) == 0 {
		return nil, &ParseError{string(b)}
	}
	for _, c := range digits {
		if c < '0' || c > '9' {
			return nil, &ParseError{string(b)}
		}
	}
	for len(digits) > 0 && digits[0] == '0' {
		digits = digits[1:]
	}
	if len(digits) == 0 {
		return &Int{}, nil
	}
	// Convert nine digits at a time from the right.
	mag := make(nat, (len(digits)+baseDigits-1)/baseDigits)
	end := len(digits)
	for i := range mag {
		start := end - baseDigits
		if start < 0 {
			start = 0
		}
		var v limb
		for _, c := range digits[start:end] {
			v = v*10 + limb(c-'0')
		}
		mag[i] = v
		end = start
	}
	return newInt(neg, mag), nil
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

// String returns the canonical decimal representation of x: no leading zeros,
// and a leading '-' only for negative values.
func (x *Int) String() string { return string(x.AppendTo(nil)) }

// AppendTo appends the canonical decimal representation of x to dst and
// returns the extended buffer. It runs in time linear in the number of digits.
func (x *Int) AppendTo(dst []byte) []byte {
	if len(x.mag) == 0 {
		return append(dst, '0')
	}
	if x.neg {
		dst = append(dst, '-')
	}
	top := len(x.mag) - 1
	dst = appendUnpadded(dst, x.mag[top])
	for i := top - 1; i >= 0; i-- {
		v := x.mag[i]
		var buf [baseDigits]byte
		for k := baseDigits - 1; k >= 0; k-- {
			buf[k] = byte('0' + v%10)
			v /= 10
		}
		dst = append(dst, buf[:]...)
	}
	return dst
}

func appendUnpadded(dst []byte, v limb) []byte {
	var buf [baseDigits]byte
	k := baseDigits
	for v != 0 {
		k--
		buf[k] = byte('0' + v%10)
		v /= 10
	}
	return append(dst, buf[k:]...)
}
