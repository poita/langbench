package jsonvalue

import (
	"math/big"
	"strings"
)

// Number is an exact decimal number: the rational value (-1)^neg * mant * 10^exp.
//
// Numbers are kept normalised (the mantissa has no trailing decimal zeros, and
// zero is always mantissa 0, exponent 0, non-negative), so two Numbers denote
// the same value exactly when their fields are equal. No binary floating point
// is involved anywhere.
//
// A Number must be treated as immutable once created.
type Number struct {
	neg    bool
	mant   *big.Int // absolute value of the mantissa
	exp    int      // decimal exponent
	digits int      // number of decimal digits in mant (0 for zero)
}

// maxExponent bounds the decimal exponents accepted by the parser so that
// exact comparison and arithmetic stay cheap.
const maxExponent = 100000

// NumberFromInt64 returns the Number denoting n.
func NumberFromInt64(n int64) Number {
	neg := n < 0
	m := new(big.Int).SetInt64(n)
	m.Abs(m)
	return newNumber(neg, m, 0)
}

// newNumber normalises (neg, mant, exp).
func newNumber(neg bool, mant *big.Int, exp int) Number {
	if mant.Sign() == 0 {
		return Number{mant: new(big.Int)}
	}
	// Strip trailing decimal zeros.
	ten := big.NewInt(10)
	q, r := new(big.Int), new(big.Int)
	for {
		q.QuoRem(mant, ten, r)
		if r.Sign() != 0 {
			break
		}
		mant, q = q, mant
		exp++
	}
	return Number{neg: neg, mant: mant, exp: exp, digits: len(mant.String())}
}

// ParseNumber parses a JSON number literal
// ([-]digits[.digits][(e|E)[+|-]digits]) exactly.
func ParseNumber(lit string) (Number, error) {
	n, rest, err := scanNumber(lit)
	if err != nil {
		err.Offset = -1
		return Number{}, err
	}
	if rest != "" {
		return Number{}, &SyntaxError{Msg: "invalid number literal " + quote(lit), Offset: -1}
	}
	return n, nil
}

// scanNumber parses a number literal at the start of s and returns the
// remainder of s.
func scanNumber(s string) (Number, string, *SyntaxError) {
	i := 0
	neg := false
	if i < len(s) && s[i] == '-' {
		neg = true
		i++
	}
	intStart := i
	if i < len(s) && s[i] == '0' {
		i++
	} else {
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
	}
	if i == intStart {
		return Number{}, "", &SyntaxError{Msg: "invalid number"}
	}
	intDigits := s[intStart:i]
	fracDigits := ""
	if i < len(s) && s[i] == '.' {
		j := i + 1
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j++
		}
		if j == i+1 {
			return Number{}, "", &SyntaxError{Msg: "invalid number: no digits after decimal point"}
		}
		fracDigits = s[i+1 : j]
		i = j
	}
	exp := 0
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		eneg := false
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			eneg = s[j] == '-'
			j++
		}
		start := j
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			exp = exp*10 + int(s[j]-'0')
			if exp > 10*maxExponent {
				return Number{}, "", &SyntaxError{Msg: "number exponent out of range"}
			}
			j++
		}
		if j == start {
			return Number{}, "", &SyntaxError{Msg: "invalid number: empty exponent"}
		}
		if eneg {
			exp = -exp
		}
		i = j
	}
	exp -= len(fracDigits)
	digits := strings.TrimLeft(intDigits+fracDigits, "0")
	// Drop trailing zeros cheaply before touching big integers.
	trimmed := strings.TrimRight(digits, "0")
	exp += len(digits) - len(trimmed)
	if exp > maxExponent || exp < -maxExponent {
		return Number{}, "", &SyntaxError{Msg: "number exponent out of range"}
	}
	if trimmed == "" {
		return Number{mant: new(big.Int)}, s[i:], nil
	}
	m, ok := new(big.Int).SetString(trimmed, 10)
	if !ok {
		return Number{}, "", &SyntaxError{Msg: "invalid number"}
	}
	return Number{neg: neg, mant: m, exp: exp, digits: len(trimmed)}, s[i:], nil
}

// Sign returns -1, 0 or +1 according to the sign of n.
func (n Number) Sign() int {
	switch {
	case n.mant == nil || n.mant.Sign() == 0:
		return 0
	case n.neg:
		return -1
	}
	return 1
}

// IsInteger reports whether n denotes a whole number (1, 1.0, 1e2, -0, ...).
func (n Number) IsInteger() bool {
	return n.Sign() == 0 || n.exp >= 0
}

// Equal reports whether a and b denote the same value.
func (a Number) Equal(b Number) bool {
	sa, sb := a.Sign(), b.Sign()
	if sa != sb {
		return false
	}
	if sa == 0 {
		return true
	}
	return a.exp == b.exp && a.mant.Cmp(b.mant) == 0
}

// Cmp compares a and b exactly, returning -1, 0 or +1.
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
	c := a.cmpAbs(b)
	if sa < 0 {
		return -c
	}
	return c
}

func (a Number) cmpAbs(b Number) int {
	// Compare orders of magnitude first; only then align exponents.
	ma, mb := a.digits+a.exp, b.digits+b.exp
	if ma != mb {
		if ma < mb {
			return -1
		}
		return 1
	}
	x, y := a.mant, b.mant
	switch {
	case a.exp > b.exp:
		x = new(big.Int).Mul(x, pow10(a.exp-b.exp))
	case a.exp < b.exp:
		y = new(big.Int).Mul(y, pow10(b.exp-a.exp))
	}
	return x.Cmp(y)
}

// IsMultipleOf reports whether a/b is an integer, computed exactly. b must be
// non-zero; if it is zero the result is false.
func (a Number) IsMultipleOf(b Number) bool {
	if b.Sign() == 0 {
		return false
	}
	if a.Sign() == 0 {
		return true
	}
	// a/b = (ma/mb) * 10^(ea-eb), with both mantissas free of trailing zeros.
	d := a.exp - b.exp
	if d >= 0 {
		// Need mb | ma*10^d.
		x := new(big.Int).Mul(a.mant, pow10(d))
		return x.Rem(x, b.mant).Sign() == 0
	}
	// Need mb*10^-d | ma.
	y := new(big.Int).Mul(b.mant, pow10(-d))
	if y.Cmp(a.mant) > 0 {
		return false
	}
	return new(big.Int).Rem(a.mant, y).Sign() == 0
}

// Int64 returns n as an int64 if it is an integer that fits.
func (n Number) Int64() (int64, bool) {
	if n.Sign() == 0 {
		return 0, true
	}
	if n.exp < 0 || n.digits+n.exp > 19 {
		return 0, false
	}
	x := new(big.Int).Mul(n.mant, pow10(n.exp))
	if n.neg {
		x.Neg(x)
	}
	if !x.IsInt64() {
		return 0, false
	}
	return x.Int64(), true
}

// String formats n in a canonical form: plain digits for small exponents,
// otherwise scientific notation (e.g. 1.5, 100, 1e+300).
func (n Number) String() string {
	if n.Sign() == 0 {
		return "0"
	}
	var sb strings.Builder
	if n.neg {
		sb.WriteByte('-')
	}
	ds := n.mant.String()
	switch {
	case n.exp >= 0 && n.exp <= 20:
		sb.WriteString(ds)
		sb.WriteString(strings.Repeat("0", n.exp))
	case n.exp < 0 && n.exp >= -20:
		if -n.exp >= len(ds) {
			sb.WriteString("0.")
			sb.WriteString(strings.Repeat("0", -n.exp-len(ds)))
			sb.WriteString(ds)
		} else {
			sb.WriteString(ds[:len(ds)+n.exp])
			sb.WriteByte('.')
			sb.WriteString(ds[len(ds)+n.exp:])
		}
	default:
		sb.WriteString(ds[:1])
		if len(ds) > 1 {
			sb.WriteByte('.')
			sb.WriteString(ds[1:])
		}
		e := n.exp + len(ds) - 1
		sb.WriteString("e")
		if e >= 0 {
			sb.WriteByte('+')
		}
		sb.WriteString(itoa(e))
	}
	return sb.String()
}

var pow10Cache [64]*big.Int

func init() {
	p := big.NewInt(1)
	for i := range pow10Cache {
		pow10Cache[i] = new(big.Int).Set(p)
		p.Mul(p, big.NewInt(10))
	}
}

func pow10(e int) *big.Int {
	if e < len(pow10Cache) {
		return pow10Cache[e]
	}
	return new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(e)), nil)
}
