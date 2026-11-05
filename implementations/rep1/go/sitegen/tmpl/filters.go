package tmpl

import (
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

type filterCode uint8

const (
	filterUnknown filterCode = iota
	filterUpper
	filterLower
	filterTrim
	filterEscape
	filterReplace
	filterLength
	filterInt
	filterJoin
	filterFirst
	filterLast
	filterReverse
	filterSort
	filterDefault
)

var filterCodes = map[string]filterCode{
	"upper": filterUpper, "lower": filterLower, "trim": filterTrim, "escape": filterEscape,
	"replace": filterReplace, "length": filterLength, "int": filterInt, "join": filterJoin,
	"first": filterFirst, "last": filterLast, "reverse": filterReverse, "sort": filterSort,
	"default": filterDefault,
}

// filterArity gives the minimum and maximum argument counts of each filter.
var filterArity = [...][2]int{
	filterUpper: {0, 0}, filterLower: {0, 0}, filterTrim: {0, 0}, filterEscape: {0, 0},
	filterReplace: {2, 2}, filterLength: {0, 0}, filterInt: {0, 0}, filterJoin: {0, 1},
	filterFirst: {0, 0}, filterLast: {0, 0}, filterReverse: {0, 0}, filterSort: {0, 0},
	filterDefault: {0, 1},
}

// applyFilter applies a filter to x with already evaluated arguments.
func applyFilter(code filterCode, x Value, args []Value) Value {
	if code != filterDefault && IsUndefined(x) {
		fail(UndefinedError, "undefined value passed to a filter")
	}
	if n := len(args); n < filterArity[code][0] || n > filterArity[code][1] {
		fail(TypeError, "wrong number of arguments to filter")
	}
	switch code {
	case filterUpper:
		return asciiCase(toString(x), true)
	case filterLower:
		return asciiCase(toString(x), false)
	case filterTrim:
		return trimWS(toString(x))
	case filterEscape:
		return htmlEscape(toString(x))
	case filterReplace:
		return strings.ReplaceAll(toString(x), toStringArg(args[0]), toStringArg(args[1]))
	case filterLength:
		switch v := x.(type) {
		case string:
			return int64(utf8.RuneCountInString(v))
		case List:
			return int64(len(v))
		case *Dict:
			return int64(v.Len())
		}
		fail(TypeError, "object has no length")
	case filterInt:
		return intFilter(x)
	case filterJoin:
		sep := ""
		if len(args) == 1 {
			sep = toStringArg(args[0])
		}
		seq := sequence(x)
		var sb strings.Builder
		for i, e := range seq {
			if i > 0 {
				sb.WriteString(sep)
			}
			writeValue(&sb, e, false)
		}
		return sb.String()
	case filterFirst:
		if s, ok := x.(string); ok {
			if s == "" {
				return Undefined
			}
			_, n := utf8.DecodeRuneInString(s)
			return s[:n]
		}
		seq := sequence(x)
		if len(seq) == 0 {
			return Undefined
		}
		return seq[0]
	case filterLast:
		if s, ok := x.(string); ok {
			if s == "" {
				return Undefined
			}
			_, n := utf8.DecodeLastRuneInString(s)
			return s[len(s)-n:]
		}
		seq := sequence(x)
		if len(seq) == 0 {
			return Undefined
		}
		return seq[len(seq)-1]
	case filterReverse:
		if s, ok := x.(string); ok {
			r := []rune(s)
			for i, j := 0, len(r)-1; i < j; i, j = i+1, j-1 {
				r[i], r[j] = r[j], r[i]
			}
			return string(r)
		}
		seq := sequence(x)
		out := make(List, len(seq))
		for i, e := range seq {
			out[len(seq)-1-i] = e
		}
		return out
	case filterSort:
		return sortFilter(sequence(x))
	case filterDefault:
		if IsUndefined(x) {
			if len(args) == 1 {
				return args[0]
			}
			return ""
		}
		return x
	}
	fail(TypeError, "unknown filter")
	return nil
}

// toStringArg converts a filter argument to a string, rejecting undefined.
func toStringArg(v Value) string {
	if IsUndefined(v) {
		fail(UndefinedError, "undefined value passed to a filter")
	}
	return toString(v)
}

func asciiCase(s string, upper bool) string {
	b := []byte(s)
	for i, c := range b {
		if upper && c >= 'a' && c <= 'z' {
			b[i] = c - 32
		} else if !upper && c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

func trimWS(s string) string { return trimRightWS(trimLeftWS(s)) }

func htmlEscape(s string) string {
	var sb strings.Builder
	last := 0
	for i := 0; i < len(s); i++ {
		var rep string
		switch s[i] {
		case '&':
			rep = "&amp;"
		case '<':
			rep = "&lt;"
		case '>':
			rep = "&gt;"
		case '"':
			rep = "&#34;"
		case '\'':
			rep = "&#39;"
		default:
			continue
		}
		sb.WriteString(s[last:i])
		sb.WriteString(rep)
		last = i + 1
	}
	if last == 0 {
		return s
	}
	sb.WriteString(s[last:])
	return sb.String()
}

// sequence returns the sequence view of a value: a list's elements, a dict's
// keys or a string's characters.
func sequence(v Value) List {
	switch x := v.(type) {
	case List:
		return x
	case *Dict:
		out := make(List, len(x.keys))
		for i, k := range x.keys {
			out[i] = k
		}
		return out
	case string:
		out := make(List, 0, len(x))
		for i := 0; i < len(x); {
			_, n := utf8.DecodeRuneInString(x[i:])
			out = append(out, x[i:i+n])
			i += n
		}
		return out
	}
	if IsUndefined(v) {
		fail(UndefinedError, "undefined value is not iterable")
	}
	fail(TypeError, "value is not a sequence")
	return nil
}

func sortFilter(seq List) Value {
	out := make(List, len(seq))
	copy(out, seq)
	allNum, allStr := true, true
	for _, e := range out {
		if !isNumber(e) {
			allNum = false
		}
		if _, ok := e.(string); !ok {
			allStr = false
		}
	}
	switch {
	case len(out) == 0:
	case allNum:
		sort.SliceStable(out, func(i, j int) bool { return numLess(out[i], out[j]) })
	case allStr:
		keys := make([]string, len(out))
		idx := make([]int, len(out))
		for i, e := range out {
			keys[i] = asciiCase(e.(string), false)
			idx[i] = i
		}
		sort.SliceStable(idx, func(a, b int) bool { return keys[idx[a]] < keys[idx[b]] })
		sorted := make(List, len(out))
		for i, k := range idx {
			sorted[i] = out[k]
		}
		out = sorted
	default:
		fail(TypeError, "cannot sort values of mixed kinds")
	}
	return out
}

func numLess(a, b Value) bool {
	_, fa := a.(float64)
	_, fb := b.(float64)
	if fa || fb {
		return toFloat(a) < toFloat(b)
	}
	return toInt64(a) < toInt64(b)
}

// intFilter implements the int filter.
func intFilter(x Value) Value {
	switch v := x.(type) {
	case int64:
		return v
	case bool:
		return toInt64(v)
	case float64:
		return int64(math.Trunc(v))
	case string:
		s := trimWS(v)
		if isIntegerString(s) {
			n, err := strconv.ParseInt(s, 10, 64)
			if err != nil {
				return int64(0)
			}
			return n
		}
		if isDecimalString(s) {
			f, err := strconv.ParseFloat(s, 64)
			if err != nil {
				return int64(0)
			}
			return int64(math.Trunc(f))
		}
	}
	return int64(0)
}

// isIntegerString matches [+-]?[0-9]+.
func isIntegerString(s string) bool {
	if s != "" && (s[0] == '+' || s[0] == '-') {
		s = s[1:]
	}
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !isDigitByte(s[i]) {
			return false
		}
	}
	return true
}

// isDecimalString matches [+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?.
func isDecimalString(s string) bool {
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i++
	}
	digits := func() int {
		start := i
		for i < len(s) && isDigitByte(s[i]) {
			i++
		}
		return i - start
	}
	intDigits := digits()
	if intDigits > 0 {
		if i < len(s) && s[i] == '.' {
			i++
			digits()
		}
	} else {
		if i >= len(s) || s[i] != '.' {
			return false
		}
		i++
		if digits() == 0 {
			return false
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		if digits() == 0 {
			return false
		}
	}
	return i == len(s)
}
