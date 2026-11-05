package template

import (
	"math"
	"strconv"
)

// wsChars are the six whitespace characters of the language.
const wsChars = " \t\n\r\f\v"

func isWS(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

// toString converts a defined value to its printed form.
func toString(v Value) string {
	if s, ok := v.(string); ok {
		return s
	}
	return string(appendValue(nil, v, false))
}

// Format returns the printed form of v, exactly as {{ v }} would render it.
// It returns an *Error of kind ErrUndefined for the undefined value.
func Format(v Value) (s string, err error) {
	defer recoverError(&err)
	return toString(v), nil
}

// appendValue appends the string form of v to b. With repr set, strings are
// quoted as inside a printed container.
func appendValue(b []byte, v Value, repr bool) []byte {
	switch x := v.(type) {
	case string:
		if repr {
			return appendQuoted(b, x)
		}
		return append(b, x...)
	case int64:
		return strconv.AppendInt(b, x, 10)
	case bool:
		if x {
			return append(b, "True"...)
		}
		return append(b, "False"...)
	case float64:
		return appendFloat(b, x)
	case noneType:
		return append(b, "None"...)
	case *List:
		b = append(b, '[')
		for i, e := range x.Items {
			if i > 0 {
				b = append(b, ", "...)
			}
			b = appendValue(b, e, true)
		}
		return append(b, ']')
	case *Dict:
		b = append(b, '{')
		for i, k := range x.keys {
			if i > 0 {
				b = append(b, ", "...)
			}
			b = appendQuoted(b, k)
			b = append(b, ": "...)
			b = appendValue(b, x.vals[i], true)
		}
		return append(b, '}')
	case undefinedType:
		throw(ErrUndefined, "printing undefined value")
	case *macroValue:
		return append(b, "<macro "+x.def.name+">"...)
	case *rangeFn:
		return append(b, "<built-in range>"...)
	case *superFn:
		return append(b, "<super>"...)
	case *loopRec:
		return append(b, "<loop>"...)
	}
	return append(b, "<?>"...)
}

// appendQuoted appends the repr of a string.
func appendQuoted(b []byte, s string) []byte {
	quote := byte('\'')
	hasSingle, hasDouble := false, false
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\'':
			hasSingle = true
		case '"':
			hasDouble = true
		}
	}
	if hasSingle && !hasDouble {
		quote = '"'
	}
	b = append(b, quote)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\':
			b = append(b, '\\', '\\')
		case c == '\n':
			b = append(b, '\\', 'n')
		case c == '\r':
			b = append(b, '\\', 'r')
		case c == '\t':
			b = append(b, '\\', 't')
		case c == quote:
			b = append(b, '\\', c)
		default:
			b = append(b, c)
		}
	}
	return append(b, quote)
}

// appendFloat appends the shortest round-trip decimal form of f, laid out
// like Python's repr: positional for decimal exponents in [-4, 16),
// scientific otherwise.
func appendFloat(b []byte, f float64) []byte {
	switch {
	case math.IsNaN(f):
		return append(b, "nan"...)
	case math.IsInf(f, 1):
		return append(b, "inf"...)
	case math.IsInf(f, -1):
		return append(b, "-inf"...)
	}
	var buf [40]byte
	s := strconv.AppendFloat(buf[:0], f, 'e', -1, 64) // [-]d[.ddd]e±XX
	if s[0] == '-' {
		b = append(b, '-')
		s = s[1:]
	}
	epos := 0
	for s[epos] != 'e' {
		epos++
	}
	exp, _ := strconv.Atoi(string(s[epos+1:]))
	if exp < -4 || exp >= 16 {
		return append(b, s...)
	}
	var digits [24]byte
	nd := 0
	for _, c := range s[:epos] {
		if c != '.' {
			digits[nd] = c
			nd++
		}
	}
	ds := digits[:nd]
	if exp >= 0 {
		if nd <= exp+1 {
			b = append(b, ds...)
			for i := nd; i < exp+1; i++ {
				b = append(b, '0')
			}
			return append(b, '.', '0')
		}
		b = append(b, ds[:exp+1]...)
		b = append(b, '.')
		return append(b, ds[exp+1:]...)
	}
	b = append(b, '0', '.')
	for i := 0; i < -exp-1; i++ {
		b = append(b, '0')
	}
	return append(b, ds...)
}
