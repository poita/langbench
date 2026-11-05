package jsonvalue

import (
	"errors"
	"math"
	"math/big"
	"math/bits"
	"strconv"
)

// Number is an exact decimal number: sign × mantissa × 10^exponent.
//
// Numbers are kept in a canonical form (the mantissa has no trailing zeros,
// and zero has exponent 0 and no sign), so that two Numbers denote the same
// rational value exactly when their fields are identical. No binary floating
// point is involved anywhere: parsing, comparison, integer tests and
// divisibility are all exact.
//
// The zero value of Number is the number 0.
type Number struct {
	neg    bool
	small  uint64   // mantissa when big == nil
	big    *big.Int // mantissa when it has more than 19 digits
	exp    int      // decimal exponent
	digits int      // number of decimal digits in the mantissa (0 for zero)
}

var pow10 = [...]uint64{
	1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000,
	1000000000, 10000000000, 100000000000, 1000000000000,
	10000000000000, 100000000000000, 1000000000000000,
	10000000000000000, 100000000000000000, 1000000000000000000,
	10000000000000000000,
}

// ErrSyntax is returned (wrapped in a *SyntaxError for the parser) for text
// that is not a valid JSON number literal.
var ErrSyntax = errors.New("invalid number literal")

// ParseNumber converts a JSON number literal
// ([-]digits[.digits][(e|E)[+|-]digits]) into an exact Number.
func ParseNumber(s string) (Number, error) {
	i := 0
	neg := false
	if i < len(s) && s[i] == '-' {
		neg = true
		i++
	}
	intStart := i
	switch {
	case i < len(s) && s[i] == '0':
		i++
	case i < len(s) && s[i] >= '1' && s[i] <= '9':
		for i < len(s) && isDigit(s[i]) {
			i++
		}
	default:
		return Number{}, ErrSyntax
	}
	intPart := s[intStart:i]
	frac := ""
	if i < len(s) && s[i] == '.' {
		i++
		fs := i
		for i < len(s) && isDigit(s[i]) {
			i++
		}
		if i == fs {
			return Number{}, ErrSyntax
		}
		frac = s[fs:i]
	}
	e := 0
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		eneg := false
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			eneg = s[i] == '-'
			i++
		}
		es := i
		for i < len(s) && isDigit(s[i]) {
			if e < 1<<28 {
				e = e*10 + int(s[i]-'0')
			}
			i++
		}
		if i == es {
			return Number{}, ErrSyntax
		}
		if eneg {
			e = -e
		}
	}
	if i != len(s) {
		return Number{}, ErrSyntax
	}
	var digits string
	if frac == "" {
		digits = intPart
	} else {
		digits = intPart + frac
	}
	return fromDigits(neg, digits, e-len(frac)), nil
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// fromDigits builds a canonical Number from a decimal digit string.
func fromDigits(neg bool, digits string, exp int) Number {
	for len(digits) > 0 && digits[0] == '0' {
		digits = digits[1:]
	}
	if digits == "" {
		return Number{}
	}
	for len(digits) > 0 && digits[len(digits)-1] == '0' {
		digits = digits[:len(digits)-1]
		exp++
	}
	n := Number{neg: neg, exp: exp, digits: len(digits)}
	if len(digits) <= 19 {
		v, _ := strconv.ParseUint(digits, 10, 64)
		n.small = v
	} else {
		n.big, _ = new(big.Int).SetString(digits, 10)
	}
	return n
}

// NumberFromInt64 returns the Number denoting v.
func NumberFromInt64(v int64) Number {
	if v == 0 {
		return Number{}
	}
	neg := v < 0
	var u uint64
	if neg {
		u = -uint64(v)
	} else {
		u = uint64(v)
	}
	return fromDigits(neg, strconv.FormatUint(u, 10), 0)
}

// IsZero reports whether n is 0.
func (n Number) IsZero() bool { return n.digits == 0 }

// Sign returns -1, 0 or +1.
func (n Number) Sign() int {
	switch {
	case n.digits == 0:
		return 0
	case n.neg:
		return -1
	}
	return 1
}

// IsInteger reports whether n denotes a whole number (1.0, 1e2 and -0 do;
// 1.5 does not).
func (n Number) IsInteger() bool { return n.digits == 0 || n.exp >= 0 }

// Equal reports whether a and b denote the same rational value.
func (a Number) Equal(b Number) bool {
	if a.neg != b.neg || a.exp != b.exp || a.small != b.small {
		return false
	}
	if a.big == nil || b.big == nil {
		return a.big == b.big
	}
	return a.big.Cmp(b.big) == 0
}

// Cmp compares a and b exactly and returns -1, 0 or +1.
func (a Number) Cmp(b Number) int {
	sa, sb := a.Sign(), b.Sign()
	if sa != sb {
		if sa < sb {
			return -1
		}
		return 1
	}
	if sa == 0 {
		return 0
	}
	c := cmpMagnitude(a, b)
	if sa < 0 {
		return -c
	}
	return c
}

func cmpMagnitude(a, b Number) int {
	ea, eb := a.exp+a.digits, b.exp+b.digits
	if ea != eb {
		if ea < eb {
			return -1
		}
		return 1
	}
	// Same order of magnitude: align the mantissas to the same digit count.
	if a.big == nil && b.big == nil {
		ma, mb := a.small, b.small
		if a.digits < b.digits {
			ma *= pow10[b.digits-a.digits]
		} else if a.digits > b.digits {
			mb *= pow10[a.digits-b.digits]
		}
		switch {
		case ma < mb:
			return -1
		case ma > mb:
			return 1
		}
		return 0
	}
	ma, mb := a.mantissa(), b.mantissa()
	if a.digits < b.digits {
		ma = new(big.Int).Mul(ma, bigPow10(b.digits-a.digits))
	} else if a.digits > b.digits {
		mb = new(big.Int).Mul(mb, bigPow10(a.digits-b.digits))
	}
	return ma.Cmp(mb)
}

func (n Number) mantissa() *big.Int {
	if n.big != nil {
		return n.big
	}
	return new(big.Int).SetUint64(n.small)
}

func bigPow10(k int) *big.Int {
	return new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(k)), nil)
}

// MultipleOf reports whether a/d is an integer, computed exactly. d must be
// non-zero; zero is a multiple of every non-zero d.
func (a Number) MultipleOf(d Number) bool {
	if d.digits == 0 {
		return false
	}
	if a.digits == 0 {
		return true
	}
	// a/d = (ma/md) × 10^(ea-ed)
	k := a.exp - d.exp
	if a.big == nil && d.big == nil {
		if k >= 0 && k < len(pow10) {
			if hi, lo := bits.Mul64(a.small, pow10[k]); hi == 0 {
				return lo%d.small == 0
			}
		} else if k < 0 && -k < len(pow10) {
			if hi, lo := bits.Mul64(d.small, pow10[-k]); hi == 0 {
				return a.small%lo == 0
			}
		}
	}
	ma, md := a.mantissa(), d.mantissa()
	var r big.Int
	if k >= 0 {
		num := new(big.Int).Mul(ma, bigPow10(k))
		return r.Rem(num, md).Sign() == 0
	}
	if d.digits-k > a.digits { // |d| × 10^-k has more digits than |a|
		return false
	}
	den := new(big.Int).Mul(md, bigPow10(-k))
	return r.Rem(ma, den).Sign() == 0
}

// Int64 returns n truncated toward zero, saturating at the int64 limits.
func (n Number) Int64() int64 {
	if n.digits == 0 {
		return 0
	}
	sat := int64(math.MaxInt64)
	if n.neg {
		sat = math.MinInt64
	}
	var mag *big.Int
	if n.exp >= 0 {
		if n.exp+n.digits > 19 {
			return sat
		}
		mag = new(big.Int).Mul(n.mantissa(), bigPow10(n.exp))
	} else {
		if -n.exp >= n.digits {
			return 0
		}
		mag = new(big.Int).Quo(n.mantissa(), bigPow10(-n.exp))
	}
	if n.neg {
		mag.Neg(mag)
	}
	if !mag.IsInt64() {
		return sat
	}
	return mag.Int64()
}

// String formats n in a canonical scientific-like form, e.g. "-12e-3".
func (n Number) String() string {
	if n.digits == 0 {
		return "0"
	}
	s := n.mantissa().String()
	if n.neg {
		s = "-" + s
	}
	if n.exp != 0 {
		s += "e" + strconv.Itoa(n.exp)
	}
	return s
}

// hash returns a hash consistent with Equal.
func (n Number) hash() uint64 {
	h := uint64(14695981039346656037)
	mix := func(x uint64) {
		h ^= x
		h *= 1099511628211
		h ^= h >> 29
	}
	if n.neg {
		mix(1)
	}
	mix(uint64(int64(n.exp)))
	if n.big == nil {
		mix(n.small)
	} else {
		for _, w := range n.big.Bits() {
			mix(uint64(w))
		}
	}
	return h
}
