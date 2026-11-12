package value

import (
	"strconv"
	"strings"
)

// Affinity is a column's type affinity.
type Affinity uint8

// Column affinities.
const (
	AffinityBlob Affinity = iota
	AffinityText
	AffinityNumeric
	AffinityInteger
	AffinityReal
)

func (a Affinity) String() string {
	switch a {
	case AffinityBlob:
		return "BLOB"
	case AffinityText:
		return "TEXT"
	case AffinityNumeric:
		return "NUMERIC"
	case AffinityInteger:
		return "INTEGER"
	case AffinityReal:
		return "REAL"
	}
	return "?"
}

// AffinityOf derives the affinity from a declared column type by applying
// SQLite's rules in order: INT, then CHAR/CLOB/TEXT, then BLOB or empty, then
// REAL/FLOA/DOUB, otherwise NUMERIC.
func AffinityOf(declaredType string) Affinity {
	t := strings.ToUpper(declaredType)
	has := strings.Contains
	switch {
	case has(t, "INT"):
		return AffinityInteger
	case has(t, "CHAR"), has(t, "CLOB"), has(t, "TEXT"):
		return AffinityText
	case has(t, "BLOB"), t == "":
		return AffinityBlob
	case has(t, "REAL"), has(t, "FLOA"), has(t, "DOUB"):
		return AffinityReal
	}
	return AffinityNumeric
}

// ApplyToLiteral converts a query literal according to the affinity of the
// column it is compared with. A number compared with a TEXT column becomes
// text; text that is entirely a numeric constant compared with an INTEGER,
// REAL or NUMERIC column becomes that number. Everything else is unchanged.
func (a Affinity) ApplyToLiteral(v Value) Value {
	switch a {
	case AffinityText:
		if v.Kind == Integer || v.Kind == Real {
			return NewText(v.String())
		}
	case AffinityInteger, AffinityReal, AffinityNumeric:
		if v.Kind == Text {
			if n, ok := ParseNumericConstant(v.Str); ok {
				return n
			}
		}
	}
	return v
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// ParseNumericConstant recognises the whole of s (ignoring leading and
// trailing spaces and tabs) as a numeric constant:
//
//	[+-]? ( digits [ "." digits? ] | "." digits ) ( [eE] [+-]? digits )?
//
// The result is an INTEGER when there is neither a "." nor an exponent and the
// value fits in an int64, and a REAL otherwise.
func ParseNumericConstant(s string) (Value, bool) {
	s = strings.Trim(s, " \t")
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i++
	}
	intDigits := 0
	for i < len(s) && isDigit(s[i]) {
		i++
		intDigits++
	}
	isInt := true
	if i < len(s) && s[i] == '.' {
		isInt = false
		i++
		frac := 0
		for i < len(s) && isDigit(s[i]) {
			i++
			frac++
		}
		if intDigits == 0 && frac == 0 {
			return Value{}, false
		}
	} else if intDigits == 0 {
		return Value{}, false
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		isInt = false
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		n := 0
		for i < len(s) && isDigit(s[i]) {
			i++
			n++
		}
		if n == 0 {
			return Value{}, false
		}
	}
	if i != len(s) {
		return Value{}, false
	}
	if isInt {
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			return NewInt(n), true
		}
	}
	f, _ := strconv.ParseFloat(s, 64) // out-of-range yields ±Inf, which is acceptable
	return NewReal(f), true
}
