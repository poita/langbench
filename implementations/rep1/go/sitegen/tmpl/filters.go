package tmpl

import (
	"math"
	"slices"
	"strconv"
	"strings"
)

// A filterDef describes one built-in filter.
type filterDef struct {
	minArgs, maxArgs int
	allowUndefined   bool
	fn               func(x Value, args []Value) Value
}

var filterTable map[string]*filterDef

func init() {
	filterTable = map[string]*filterDef{
		"upper":   {0, 0, false, func(x Value, _ []Value) Value { return asciiUpper(toString(x)) }},
		"lower":   {0, 0, false, func(x Value, _ []Value) Value { return asciiLower(toString(x)) }},
		"trim":    {0, 0, false, func(x Value, _ []Value) Value { return strings.Trim(toString(x), wsChars) }},
		"escape":  {0, 0, false, func(x Value, _ []Value) Value { return escapeHTML(toString(x)) }},
		"replace": {2, 2, false, filterReplace},
		"length":  {0, 0, false, filterLength},
		"int":     {0, 0, false, func(x Value, _ []Value) Value { return toInt(x) }},
		"join":    {0, 1, false, filterJoin},
		"first":   {0, 0, false, func(x Value, _ []Value) Value { return firstLast(x, true) }},
		"last":    {0, 0, false, func(x Value, _ []Value) Value { return firstLast(x, false) }},
		"reverse": {0, 0, false, filterReverse},
		"sort":    {0, 0, false, filterSort},
		"default": {0, 1, true, filterDefault},
	}
}

func asciiUpper(s string) string {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c >= 'a' && c <= 'z' {
			b := []byte(s)
			for j := i; j < len(b); j++ {
				if b[j] >= 'a' && b[j] <= 'z' {
					b[j] -= 'a' - 'A'
				}
			}
			return string(b)
		}
	}
	return s
}

func asciiLower(s string) string {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c >= 'A' && c <= 'Z' {
			b := []byte(s)
			for j := i; j < len(b); j++ {
				if b[j] >= 'A' && b[j] <= 'Z' {
					b[j] += 'a' - 'A'
				}
			}
			return string(b)
		}
	}
	return s
}

func escapeHTML(s string) string {
	if !strings.ContainsAny(s, `&<>"'`) {
		return s
	}
	var b strings.Builder
	b.Grow(len(s) + 16)
	for i := 0; i < len(s); i++ {
		switch c := s[i]; c {
		case '&':
			b.WriteString("&amp;")
		case '<':
			b.WriteString("&lt;")
		case '>':
			b.WriteString("&gt;")
		case '"':
			b.WriteString("&#34;")
		case '\'':
			b.WriteString("&#39;")
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

func filterReplace(x Value, args []Value) Value {
	return strings.ReplaceAll(toString(x), toString(args[0]), toString(args[1]))
}

func filterLength(x Value, _ []Value) Value {
	switch v := x.(type) {
	case string:
		n := int64(0)
		for range v {
			n++
		}
		return n
	case []Value:
		return int64(len(v))
	case *Dict:
		return int64(v.Len())
	}
	throw(KindType, "length of a value without a length")
	return nil
}

func filterJoin(x Value, args []Value) Value {
	sep := ""
	if len(args) == 1 {
		sep = toString(args[0])
	}
	items := sequence(x)
	var b strings.Builder
	for i, it := range items {
		if i > 0 {
			b.WriteString(sep)
		}
		b.WriteString(toString(it))
	}
	return b.String()
}

func firstLast(x Value, first bool) Value {
	items := sequence(x)
	if len(items) == 0 {
		return Undefined
	}
	if first {
		return items[0]
	}
	return items[len(items)-1]
}

func filterReverse(x Value, _ []Value) Value {
	if s, ok := x.(string); ok {
		r := []rune(s)
		slices.Reverse(r)
		return string(r)
	}
	items := sequence(x)
	out := make([]Value, len(items))
	for i, it := range items {
		out[len(items)-1-i] = it
	}
	return out
}

func filterSort(x Value, _ []Value) Value {
	items := slices.Clone(sequence(x))
	allNum, allStr := true, true
	for _, it := range items {
		if _, _, k := toNum(it); k == numNone {
			allNum = false
		}
		if _, ok := it.(string); !ok {
			allStr = false
		}
	}
	switch {
	case len(items) == 0:
	case allNum:
		slices.SortStableFunc(items, order)
	case allStr:
		keys := make(map[string]string, len(items))
		for _, it := range items {
			s := it.(string)
			keys[s] = asciiLower(s)
		}
		slices.SortStableFunc(items, func(a, b Value) int {
			return strings.Compare(keys[a.(string)], keys[b.(string)])
		})
	default:
		throw(KindType, "cannot sort a mix of values")
	}
	if items == nil {
		items = []Value{}
	}
	return items
}

func filterDefault(x Value, args []Value) Value {
	if isUndef(x) {
		if len(args) == 1 {
			return args[0]
		}
		return ""
	}
	return x
}

// toInt implements the int filter.
func toInt(x Value) Value {
	switch v := x.(type) {
	case int64:
		return v
	case float64:
		return truncFloat(v)
	case bool:
		return b2i(v)
	case string:
		return parseIntString(strings.Trim(v, wsChars))
	}
	return int64(0)
}

func truncFloat(f float64) int64 {
	if math.IsNaN(f) {
		return 0
	}
	return int64(f)
}

// parseIntString converts a trimmed string the way the int filter does.
func parseIntString(s string) int64 {
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i++
	}
	j := i
	for j < len(s) && isDigit(s[j]) {
		j++
	}
	if j == len(s) && j > i {
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			return n
		}
		return 0
	}
	// Decimal: ([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?
	k := j
	if k < len(s) && s[k] == '.' {
		k++
		for k < len(s) && isDigit(s[k]) {
			k++
		}
	}
	if j == i && k-j < 2 { // no digits at all
		return 0
	}
	if k < len(s) && (s[k] == 'e' || s[k] == 'E') {
		m := k + 1
		if m < len(s) && (s[m] == '+' || s[m] == '-') {
			m++
		}
		d := m
		for m < len(s) && isDigit(s[m]) {
			m++
		}
		if m == d {
			return 0
		}
		k = m
	}
	if k != len(s) {
		return 0
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0
	}
	return truncFloat(f)
}
