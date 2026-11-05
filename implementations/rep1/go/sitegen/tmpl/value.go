package tmpl

import (
	"math"
	"strconv"
	"strings"
)

// Value is a template value: nil (none), bool, int64, float64, string, List,
// *Dict, or Undefined. Other types are not valid.
type Value = any

// List is a list value.
type List []Value

type undefinedType struct{}

// Undefined is the template "undefined" value.
var Undefined Value = undefinedType{}

// IsUndefined reports whether v is the undefined value.
func IsUndefined(v Value) bool {
	_, ok := v.(undefinedType)
	return ok
}

// Normalize converts common Go values to template values: all integer types
// become int64, float32 becomes float64 and []string becomes a List.
func Normalize(v any) Value {
	switch x := v.(type) {
	case int:
		return int64(x)
	case int8:
		return int64(x)
	case int16:
		return int64(x)
	case int32:
		return int64(x)
	case uint:
		return int64(x)
	case uint8:
		return int64(x)
	case uint16:
		return int64(x)
	case uint32:
		return int64(x)
	case float32:
		return float64(x)
	case []string:
		return StringList(x)
	}
	return v
}

// StringList converts a slice of strings to a List.
func StringList(ss []string) List {
	l := make(List, len(ss))
	for i, s := range ss {
		l[i] = s
	}
	return l
}

const smallDict = 8

// Dict is an insertion-ordered mapping from string keys to values.
type Dict struct {
	keys  []string
	vals  []Value
	index map[string]int // built once the dict grows beyond smallDict entries
}

// NewDict returns an empty dict.
func NewDict() *Dict { return &Dict{} }

// Len returns the number of members.
func (d *Dict) Len() int { return len(d.keys) }

// Keys returns the keys in insertion order. The slice must not be modified.
func (d *Dict) Keys() []string { return d.keys }

func (d *Dict) find(key string) int {
	if d.index != nil {
		if i, ok := d.index[key]; ok {
			return i
		}
		return -1
	}
	for i, k := range d.keys {
		if k == key {
			return i
		}
	}
	return -1
}

// Get returns the member named key.
func (d *Dict) Get(key string) (Value, bool) {
	if i := d.find(key); i >= 0 {
		return d.vals[i], true
	}
	return nil, false
}

// Set stores a member, replacing the value of an existing key (keeping its
// position) or appending a new one. The value is passed through Normalize.
func (d *Dict) Set(key string, v Value) {
	v = Normalize(v)
	if i := d.find(key); i >= 0 {
		d.vals[i] = v
		return
	}
	d.keys = append(d.keys, key)
	d.vals = append(d.vals, v)
	if d.index != nil {
		d.index[key] = len(d.keys) - 1
	} else if len(d.keys) > smallDict {
		d.index = make(map[string]int, 2*len(d.keys))
		for i, k := range d.keys {
			d.index[k] = i
		}
	}
}

// ---- conversions ----

func isNumber(v Value) bool {
	switch v.(type) {
	case int64, float64, bool:
		return true
	}
	return false
}

func toFloat(v Value) float64 {
	switch x := v.(type) {
	case int64:
		return float64(x)
	case float64:
		return x
	case bool:
		if x {
			return 1
		}
	}
	return 0
}

// toInt64 converts an int64 or bool to int64.
func toInt64(v Value) int64 {
	switch x := v.(type) {
	case int64:
		return x
	case bool:
		if x {
			return 1
		}
	}
	return 0
}

func isIntLike(v Value) bool {
	switch v.(type) {
	case int64, bool:
		return true
	}
	return false
}

// truthy implements Python truthiness; the caller must have excluded undefined.
func truthy(v Value) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case int64:
		return x != 0
	case float64:
		return x != 0
	case string:
		return x != ""
	case List:
		return len(x) > 0
	case *Dict:
		return x.Len() > 0
	}
	return true
}

// formatFloat renders a float like Python's repr.
func formatFloat(f float64) string {
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	if math.IsInf(f, 0) || math.IsNaN(f) {
		return strconv.FormatFloat(f, 'g', -1, 64)
	}
	s := strconv.FormatFloat(f, 'e', -1, 64)
	neg := s[0] == '-'
	if neg {
		s = s[1:]
	}
	epos := strings.IndexByte(s, 'e')
	exp, _ := strconv.Atoi(s[epos+1:])
	digits := strings.Replace(s[:epos], ".", "", 1)
	var out string
	switch {
	case exp < -4 || exp >= 16:
		out = s
	case exp >= 0:
		if len(digits) <= exp+1 {
			out = digits + strings.Repeat("0", exp+1-len(digits)) + ".0"
		} else {
			out = digits[:exp+1] + "." + digits[exp+1:]
		}
	default:
		out = "0." + strings.Repeat("0", -exp-1) + digits
	}
	if neg {
		return "-" + out
	}
	return out
}

// writeValue appends the printed form of v. With repr set, strings are quoted
// (as inside lists and dicts).
func writeValue(sb *strings.Builder, v Value, repr bool) {
	switch x := v.(type) {
	case nil:
		sb.WriteString("None")
	case bool:
		if x {
			sb.WriteString("True")
		} else {
			sb.WriteString("False")
		}
	case int64:
		var buf [24]byte
		sb.Write(strconv.AppendInt(buf[:0], x, 10))
	case float64:
		sb.WriteString(formatFloat(x))
	case string:
		if repr {
			writeQuoted(sb, x)
		} else {
			sb.WriteString(x)
		}
	case List:
		sb.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				sb.WriteString(", ")
			}
			writeValue(sb, e, true)
		}
		sb.WriteByte(']')
	case *Dict:
		sb.WriteByte('{')
		for i, k := range x.keys {
			if i > 0 {
				sb.WriteString(", ")
			}
			writeQuoted(sb, k)
			sb.WriteString(": ")
			writeValue(sb, x.vals[i], true)
		}
		sb.WriteByte('}')
	case *macroVal:
		sb.WriteString("<macro " + x.def.name + ">")
	default:
		sb.WriteString("<builtin>")
	}
}

func writeQuoted(sb *strings.Builder, s string) {
	quote := byte('\'')
	if strings.IndexByte(s, '\'') >= 0 && strings.IndexByte(s, '"') < 0 {
		quote = '"'
	}
	sb.WriteByte(quote)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\':
			sb.WriteString(`\\`)
		case c == '\n':
			sb.WriteString(`\n`)
		case c == '\r':
			sb.WriteString(`\r`)
		case c == '\t':
			sb.WriteString(`\t`)
		case c == quote:
			sb.WriteByte('\\')
			sb.WriteByte(c)
		default:
			sb.WriteByte(c)
		}
	}
	sb.WriteByte(quote)
}

// toString converts a defined value to its printed form.
func toString(v Value) string {
	if s, ok := v.(string); ok {
		return s
	}
	var sb strings.Builder
	writeValue(&sb, v, false)
	return sb.String()
}

// equals implements == for defined values.
func equals(a, b Value) bool {
	if isNumber(a) && isNumber(b) {
		_, fa := a.(float64)
		_, fb := b.(float64)
		if fa || fb {
			return toFloat(a) == toFloat(b)
		}
		return toInt64(a) == toInt64(b)
	}
	switch x := a.(type) {
	case nil:
		return b == nil
	case string:
		y, ok := b.(string)
		return ok && x == y
	case List:
		y, ok := b.(List)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !equals(x[i], y[i]) {
				return false
			}
		}
		return true
	case *Dict:
		y, ok := b.(*Dict)
		if !ok || x.Len() != y.Len() {
			return false
		}
		if x == y {
			return true
		}
		for i, k := range x.keys {
			w, found := y.Get(k)
			if !found || !equals(x.vals[i], w) {
				return false
			}
		}
		return true
	}
	return a == b
}
