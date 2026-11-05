package bigint

// Parse converts a decimal integer of the form -?[0-9]+ into an Int. Leading
// zeros are accepted, and "-0" (any number of zeros) is zero. Parsing is
// linear in the length of s.
func Parse(s string) (Int, error) { return ParseBytes([]byte(s)) }

// ParseBytes is like Parse but reads from a byte slice without copying it.
func ParseBytes(b []byte) (Int, error) {
	neg := false
	if len(b) > 0 && b[0] == '-' {
		neg = true
		b = b[1:]
	}
	if len(b) == 0 {
		return Int{}, ErrSyntax
	}
	for _, c := range b {
		if c < '0' || c > '9' {
			return Int{}, ErrSyntax
		}
	}
	for len(b) > 0 && b[0] == '0' {
		b = b[1:]
	}
	if len(b) == 0 {
		return Int{}, nil
	}
	mag := make(nat, (len(b)+baseDigits-1)/baseDigits)
	end := len(b)
	for i := range mag {
		start := end - baseDigits
		if start < 0 {
			start = 0
		}
		var limb uint32
		for _, c := range b[start:end] {
			limb = limb*10 + uint32(c-'0')
		}
		mag[i] = limb
		end = start
	}
	return Int{neg, mag}, nil
}

// MustParse is like Parse but panics on error. It is intended for tests and
// constants.
func MustParse(s string) Int {
	x, err := Parse(s)
	if err != nil {
		panic(err)
	}
	return x
}

// String returns the canonical decimal form of x: no leading zeros, a leading
// "-" only for negative values, and "0" for zero.
func (x Int) String() string { return string(x.AppendTo(nil)) }

// AppendTo appends the canonical decimal form of x to buf and returns the
// extended buffer. It runs in time linear in the number of limbs.
func (x Int) AppendTo(buf []byte) []byte {
	if len(x.mag) == 0 {
		return append(buf, '0')
	}
	if x.neg {
		buf = append(buf, '-')
	}
	top := len(x.mag) - 1
	buf = appendLimb(buf, x.mag[top], false)
	for i := top - 1; i >= 0; i-- {
		buf = appendLimb(buf, x.mag[i], true)
	}
	return buf
}

// appendLimb appends v in decimal, zero-padded to nine digits if pad is set.
func appendLimb(buf []byte, v uint32, pad bool) []byte {
	var tmp [baseDigits]byte
	i := baseDigits
	for v != 0 || (pad && i > 0) {
		i--
		tmp[i] = byte('0' + v%10)
		v /= 10
	}
	return append(buf, tmp[i:]...)
}
