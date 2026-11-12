package value

import (
	"math"
	"reflect"
	"sort"
	"strconv"
	"strings"

	"example.com/template/tplerr"
)

func undefinedError(what string) error {
	return tplerr.New(tplerr.Undefined, "%s", what)
}

func typeError(format string, args ...any) error {
	return tplerr.New(tplerr.Type, format, args...)
}

// ToString returns the printed form of v (strings as-is, booleans as
// True/False, none as None, lists and dicts with repr elements). The
// undefined value is an undefined error.
func ToString(v Value) (string, error) {
	if s, ok := v.(string); ok {
		return s, nil
	}
	b, err := AppendString(nil, v)
	return string(b), err
}

// AppendString appends the printed form of v to dst.
func AppendString(dst []byte, v Value) ([]byte, error) {
	return appendValue(dst, v, false)
}

// Repr returns the repr form of v: like ToString except that strings are
// quoted and escaped.
func Repr(v Value) (string, error) {
	b, err := appendValue(nil, v, true)
	return string(b), err
}

func appendValue(dst []byte, v Value, repr bool) ([]byte, error) {
	switch x := v.(type) {
	case string:
		if repr {
			return appendQuoted(dst, x), nil
		}
		return append(dst, x...), nil
	case int64:
		return strconv.AppendInt(dst, x, 10), nil
	case float64:
		return append(dst, FormatFloat(x)...), nil
	case bool:
		if x {
			return append(dst, "True"...), nil
		}
		return append(dst, "False"...), nil
	case NoneType:
		return append(dst, "None"...), nil
	case *List:
		dst = append(dst, '[')
		for i, e := range x.Items {
			if i > 0 {
				dst = append(dst, ", "...)
			}
			var err error
			if dst, err = appendValue(dst, e, true); err != nil {
				return dst, err
			}
		}
		return append(dst, ']'), nil
	case *Dict:
		dst = append(dst, '{')
		for i, k := range x.keys {
			if i > 0 {
				dst = append(dst, ", "...)
			}
			dst = appendQuoted(dst, k)
			dst = append(dst, ": "...)
			var err error
			if dst, err = appendValue(dst, x.vals[i], true); err != nil {
				return dst, err
			}
		}
		return append(dst, '}'), nil
	case *Loop:
		for i, name := range []string{"index", "index0", "first", "last", "length"} {
			if i == 0 {
				dst = append(dst, '{')
			} else {
				dst = append(dst, ", "...)
			}
			m, _ := x.Member(name)
			dst = append(dst, '\'')
			dst = append(dst, name...)
			dst = append(dst, "': "...)
			dst, _ = appendValue(dst, m, true)
		}
		return append(dst, '}'), nil
	case UndefinedType:
		return dst, undefinedError("printing the undefined value")
	case Callable:
		return append(dst, "<"+x.CallableName()+">"...), nil
	}
	return dst, typeError("cannot print value of type %T", v)
}

// appendQuoted appends the Python-style quoted form of s.
func appendQuoted(dst []byte, s string) []byte {
	quote := byte('\'')
	if strings.IndexByte(s, '\'') >= 0 && strings.IndexByte(s, '"') < 0 {
		quote = '"'
	}
	dst = append(dst, quote)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\':
			dst = append(dst, '\\', '\\')
		case c == '\n':
			dst = append(dst, '\\', 'n')
		case c == '\r':
			dst = append(dst, '\\', 'r')
		case c == '\t':
			dst = append(dst, '\\', 't')
		case c == quote:
			dst = append(dst, '\\', c)
		default:
			dst = append(dst, c)
		}
	}
	return append(dst, quote)
}

// FormatFloat formats f the way the printed form of a float requires: the
// shortest round-tripping digits, positional notation for decimal exponents
// in [-4, 16) with at least one fractional digit, scientific notation
// otherwise.
func FormatFloat(f float64) string {
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
	s := strconv.FormatFloat(f, 'e', -1, 64) // [-]d[.ddd]e±XX
	neg := s[0] == '-'
	if neg {
		s = s[1:]
	}
	ePos := strings.IndexByte(s, 'e')
	exp, _ := strconv.Atoi(s[ePos+1:])
	if exp < -4 || exp >= 16 {
		if neg {
			return "-" + s
		}
		return s
	}
	digits := strings.Replace(s[:ePos], ".", "", 1)
	var b strings.Builder
	if neg {
		b.WriteByte('-')
	}
	if exp >= 0 {
		if len(digits) <= exp+1 {
			b.WriteString(digits)
			b.WriteString(strings.Repeat("0", exp+1-len(digits)))
			b.WriteString(".0")
		} else {
			b.WriteString(digits[:exp+1])
			b.WriteByte('.')
			b.WriteString(digits[exp+1:])
		}
	} else {
		b.WriteString("0.")
		b.WriteString(strings.Repeat("0", -exp-1))
		b.WriteString(digits)
	}
	return b.String()
}

// FromGo converts an ordinary Go value into a template value. It accepts
// nil, bool, all integer and float types, string, []any, map[string]any
// (keys in sorted order), existing template values, and, via reflection,
// other slices, arrays and string-keyed maps. Anything else is a type error.
func FromGo(x any) (Value, error) {
	switch v := x.(type) {
	case nil:
		return None, nil
	case bool, string, int64, float64, NoneType, *List, *Dict, UndefinedType:
		return v, nil
	case int:
		return int64(v), nil
	case float32:
		return float64(v), nil
	case []any:
		items := make([]Value, len(v))
		for i, e := range v {
			c, err := FromGo(e)
			if err != nil {
				return nil, err
			}
			items[i] = c
		}
		return NewList(items), nil
	case map[string]any:
		keys := make([]string, 0, len(v))
		for k := range v {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		d := NewDict(len(keys))
		for _, k := range keys {
			c, err := FromGo(v[k])
			if err != nil {
				return nil, err
			}
			d.Set(k, c)
		}
		return d, nil
	}
	rv := reflect.ValueOf(x)
	switch rv.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32:
		return rv.Int(), nil
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32:
		return int64(rv.Uint()), nil
	case reflect.String:
		return rv.String(), nil
	case reflect.Bool:
		return rv.Bool(), nil
	case reflect.Slice, reflect.Array:
		items := make([]Value, rv.Len())
		for i := range items {
			c, err := FromGo(rv.Index(i).Interface())
			if err != nil {
				return nil, err
			}
			items[i] = c
		}
		return NewList(items), nil
	case reflect.Map:
		if rv.Type().Key().Kind() == reflect.String {
			m := make(map[string]any, rv.Len())
			for _, k := range rv.MapKeys() {
				m[k.String()] = rv.MapIndex(k).Interface()
			}
			return FromGo(m)
		}
	}
	return nil, typeError("cannot convert Go value of type %T", x)
}
