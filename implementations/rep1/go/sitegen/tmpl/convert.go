package tmpl

import (
	"math"
	"strconv"
	"strings"
)

// toString converts v to a string as printing does.
func toString(v Value) string {
	switch x := v.(type) {
	case string:
		return x
	case int64:
		return strconv.FormatInt(x, 10)
	case float64:
		return formatFloat(x)
	case bool:
		if x {
			return "True"
		}
		return "False"
	case noneType:
		return "None"
	case []Value, *Dict:
		var b strings.Builder
		writeRepr(&b, v)
		return b.String()
	case undefinedType:
		throw(KindUndefined, "printing an undefined value")
	case *macroVal:
		return "<macro " + x.def.name + ">"
	}
	return ""
}

func writeRepr(b *strings.Builder, v Value) {
	switch x := v.(type) {
	case string:
		writeStringRepr(b, x)
	case []Value:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteString(", ")
			}
			writeRepr(b, e)
		}
		b.WriteByte(']')
	case *Dict:
		b.WriteByte('{')
		for i, k := range x.keys {
			if i > 0 {
				b.WriteString(", ")
			}
			writeStringRepr(b, k)
			b.WriteString(": ")
			writeRepr(b, x.m[k])
		}
		b.WriteByte('}')
	default:
		b.WriteString(toString(v))
	}
}

func writeStringRepr(b *strings.Builder, s string) {
	quote := byte('\'')
	if strings.IndexByte(s, '\'') >= 0 && strings.IndexByte(s, '"') < 0 {
		quote = '"'
	}
	b.WriteByte(quote)
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '\\':
			b.WriteString(`\\`)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
		case c == quote:
			b.WriteByte('\\')
			b.WriteByte(c)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte(quote)
}

// formatFloat formats f like Python's repr: the shortest digits that round
// trip, in positional notation for decimal exponents in [-4, 16).
func formatFloat(f float64) string {
	switch {
	case math.IsNaN(f):
		return "nan"
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	case f == 0:
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	s := strconv.FormatFloat(f, 'e', -1, 64)
	sign := ""
	if s[0] == '-' {
		sign, s = "-", s[1:]
	}
	ePos := strings.IndexByte(s, 'e')
	mant, expStr := s[:ePos], s[ePos+1:]
	exp, _ := strconv.Atoi(expStr)
	digits := strings.Replace(mant, ".", "", 1)
	if exp >= -4 && exp < 16 {
		if exp >= 0 {
			for len(digits) < exp+1 {
				digits += "0"
			}
			frac := digits[exp+1:]
			if frac == "" {
				frac = "0"
			}
			return sign + digits[:exp+1] + "." + frac
		}
		return sign + "0." + strings.Repeat("0", -exp-1) + digits
	}
	es := "+"
	if exp < 0 {
		es, exp = "-", -exp
	}
	e := strconv.Itoa(exp)
	if len(e) < 2 {
		e = "0" + e
	}
	return sign + mant + "e" + es + e
}
