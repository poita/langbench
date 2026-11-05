package template

import (
	"cmp"
	"math"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

// applyFilter runs one filter. in is the evaluated input and args the
// evaluated arguments.
func applyFilter(code filterCode, in Value, args []Value) Value {
	if code == filterDefault {
		if len(args) > 1 {
			throw(ErrType, "default takes at most one argument")
		}
		if IsUndefined(in) {
			if len(args) == 1 {
				return args[0]
			}
			return ""
		}
		return in
	}
	if IsUndefined(in) {
		throw(ErrUndefined, "filter applied to undefined value")
	}
	want := 0
	switch code {
	case filterReplace:
		want = 2
	case filterJoin:
		if len(args) > 1 {
			throw(ErrType, "join takes at most one argument")
		}
		want = len(args)
	}
	if len(args) != want {
		throw(ErrType, "wrong number of filter arguments")
	}
	switch code {
	case filterUpper:
		return mapASCII(toString(in), 'a', 'z', -32)
	case filterLower:
		return mapASCII(toString(in), 'A', 'Z', 32)
	case filterTrim:
		return strings.Trim(toString(in), wsChars)
	case filterEscape:
		return escapeHTML(toString(in))
	case filterReplace:
		return strings.ReplaceAll(toString(in), toString(args[0]), toString(args[1]))
	case filterLength:
		switch x := in.(type) {
		case string:
			return int64(utf8.RuneCountInString(x))
		case *List:
			return int64(len(x.Items))
		case *Dict:
			return int64(x.Len())
		}
		throw(ErrType, "object has no length")
	case filterInt:
		return toInt(in)
	case filterJoin:
		sep := ""
		if len(args) == 1 {
			sep = toString(args[0])
		}
		return joinValues(seqView(in), sep)
	case filterFirst:
		return firstLast(in, true)
	case filterLast:
		return firstLast(in, false)
	case filterReverse:
		if s, ok := in.(string); ok {
			return reverseString(s)
		}
		items := seqView(in)
		out := make([]Value, len(items))
		for i, v := range items {
			out[len(items)-1-i] = v
		}
		return &List{Items: out}
	case filterSort:
		return sortValues(seqView(in))
	}
	throw(ErrFilter, "unknown filter")
	return nil
}

func mapASCII(s string, lo, hi byte, delta int) string {
	i := 0
	for ; i < len(s); i++ {
		if s[i] >= lo && s[i] <= hi {
			break
		}
	}
	if i == len(s) {
		return s
	}
	b := []byte(s)
	for ; i < len(b); i++ {
		if b[i] >= lo && b[i] <= hi {
			b[i] = byte(int(b[i]) + delta)
		}
	}
	return string(b)
}

func escapeHTML(s string) string {
	if !strings.ContainsAny(s, "&<>\"'") {
		return s
	}
	var sb strings.Builder
	sb.Grow(len(s) + 16)
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '&':
			sb.WriteString("&amp;")
		case '<':
			sb.WriteString("&lt;")
		case '>':
			sb.WriteString("&gt;")
		case '"':
			sb.WriteString("&#34;")
		case '\'':
			sb.WriteString("&#39;")
		default:
			sb.WriteByte(s[i])
		}
	}
	return sb.String()
}

func joinValues(items []Value, sep string) string {
	var b []byte
	for i, v := range items {
		if i > 0 {
			b = append(b, sep...)
		}
		b = appendValue(b, v, false)
	}
	return string(b)
}

func reverseString(s string) string {
	b := make([]byte, 0, len(s))
	for i := len(s); i > 0; {
		r, size := utf8.DecodeLastRuneInString(s[:i])
		b = utf8.AppendRune(b, r)
		i -= size
	}
	return string(b)
}

func firstLast(in Value, first bool) Value {
	switch x := in.(type) {
	case *List:
		if len(x.Items) == 0 {
			return Undefined
		}
		if first {
			return x.Items[0]
		}
		return x.Items[len(x.Items)-1]
	case *Dict:
		if x.Len() == 0 {
			return Undefined
		}
		if first {
			return x.keys[0]
		}
		return x.keys[len(x.keys)-1]
	case string:
		if x == "" {
			return Undefined
		}
		if first {
			_, size := utf8.DecodeRuneInString(x)
			return x[:size]
		}
		_, size := utf8.DecodeLastRuneInString(x)
		return x[len(x)-size:]
	}
	throw(ErrType, "value is not a sequence")
	return nil
}

// toInt implements the int filter.
func toInt(v Value) Value {
	switch x := v.(type) {
	case int64:
		return x
	case bool:
		if x {
			return int64(1)
		}
		return int64(0)
	case float64:
		return floatToInt(x)
	case string:
		return intFromString(x)
	}
	return int64(0)
}

func floatToInt(f float64) int64 {
	f = math.Trunc(f)
	switch {
	case f >= 9.223372036854775807e18:
		return math.MaxInt64
	case f <= -9.223372036854775808e18:
		return math.MinInt64
	case f != f:
		return 0
	}
	return int64(f)
}

func intFromString(s string) int64 {
	s = strings.Trim(s, wsChars)
	if isIntForm(s) {
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			return n
		}
	}
	if isDecimalForm(s) {
		f, _ := strconv.ParseFloat(s, 64)
		return floatToInt(f)
	}
	return 0
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// isIntForm matches [+-]?[0-9]+.
func isIntForm(s string) bool {
	if s != "" && (s[0] == '+' || s[0] == '-') {
		s = s[1:]
	}
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !isDigit(s[i]) {
			return false
		}
	}
	return true
}

// isDecimalForm matches [+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?.
func isDecimalForm(s string) bool {
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i++
	}
	intDigits := 0
	for i < len(s) && isDigit(s[i]) {
		i++
		intDigits++
	}
	if intDigits > 0 {
		if i < len(s) && s[i] == '.' {
			i++
			for i < len(s) && isDigit(s[i]) {
				i++
			}
		}
	} else {
		if i >= len(s) || s[i] != '.' {
			return false
		}
		i++
		frac := 0
		for i < len(s) && isDigit(s[i]) {
			i++
			frac++
		}
		if frac == 0 {
			return false
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		exp := 0
		for i < len(s) && isDigit(s[i]) {
			i++
			exp++
		}
		if exp == 0 {
			return false
		}
	}
	return i == len(s)
}

// sortValues implements the sort filter: a stable ascending sort of all
// numbers, or of all strings by their ASCII-lowercased form.
func sortValues(items []Value) Value {
	out := make([]Value, len(items))
	copy(out, items)
	if len(out) < 2 {
		return &List{Items: out}
	}
	allNum, allStr := true, true
	for _, v := range out {
		if _, _, k := num(v); k == nkNone {
			allNum = false
		}
		if _, ok := v.(string); !ok {
			allStr = false
		}
	}
	switch {
	case allNum:
		slices.SortStableFunc(out, func(a, b Value) int {
			ai, af, ak := num(a)
			bi, bf, bk := num(b)
			if ak == nkInt && bk == nkInt {
				return cmp.Compare(ai, bi)
			}
			return cmp.Compare(asFloat(ai, af, ak), asFloat(bi, bf, bk))
		})
	case allStr:
		type keyed struct {
			key string
			v   Value
		}
		ks := make([]keyed, len(out))
		for i, v := range out {
			ks[i] = keyed{mapASCII(v.(string), 'A', 'Z', 32), v}
		}
		slices.SortStableFunc(ks, func(a, b keyed) int { return strings.Compare(a.key, b.key) })
		for i := range ks {
			out[i] = ks[i].v
		}
	default:
		throw(ErrType, "cannot sort a mix of value kinds")
	}
	return &List{Items: out}
}
