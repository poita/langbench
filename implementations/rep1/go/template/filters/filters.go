// Package filters implements the thirteen built-in template filters:
// upper, lower, trim, escape, replace, length, int, join, first, last,
// reverse, sort and default.
package filters

import (
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"example.com/template/tplerr"
	"example.com/template/value"
)

// whitespace is the set of characters trimmed by trim and by int.
const whitespace = " \t\n\r\f\v"

type filter struct {
	minArgs, maxArgs int
	fn               func(in value.Value, args []value.Value) (value.Value, error)
}

var table map[string]filter

func init() {
	table = map[string]filter{
		"upper":   {0, 0, upper},
		"lower":   {0, 0, lower},
		"trim":    {0, 0, trim},
		"escape":  {0, 0, escape},
		"replace": {2, 2, replace},
		"length":  {0, 0, length},
		"int":     {0, 0, toInt},
		"join":    {0, 1, join},
		"first":   {0, 0, first},
		"last":    {0, 0, last},
		"reverse": {0, 0, reverse},
		"sort":    {0, 0, sortFilter},
		"default": {0, 1, defaultFilter},
	}
}

// Has reports whether name is a known filter.
func Has(name string) bool {
	_, ok := table[name]
	return ok
}

// Names returns the names of the known filters, sorted.
func Names() []string {
	names := make([]string, 0, len(table))
	for n := range table {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// Apply runs the named filter on an already evaluated input and arguments.
// An unknown name is a filter error. Except for default, an undefined input
// is an undefined error; only then is the argument count checked (a type
// error).
func Apply(name string, in value.Value, args []value.Value) (value.Value, error) {
	f, ok := table[name]
	if !ok {
		return nil, tplerr.New(tplerr.Filter, "unknown filter %q", name)
	}
	if name != "default" && value.IsUndefined(in) {
		return nil, tplerr.New(tplerr.Undefined, "filter %s applied to the undefined value", name)
	}
	if len(args) < f.minArgs || len(args) > f.maxArgs {
		return nil, tplerr.New(tplerr.Type, "filter %s: wrong number of arguments (%d)", name, len(args))
	}
	return f.fn(in, args)
}

func asciiMap(s string, from, to byte) string {
	i := 0
	for i < len(s) && (s[i] < from || s[i] > to) {
		i++
	}
	if i == len(s) {
		return s
	}
	b := []byte(s)
	for ; i < len(b); i++ {
		if b[i] >= from && b[i] <= to {
			b[i] ^= 0x20
		}
	}
	return string(b)
}

func upper(in value.Value, _ []value.Value) (value.Value, error) {
	s, err := value.ToString(in)
	if err != nil {
		return nil, err
	}
	return asciiMap(s, 'a', 'z'), nil
}

func lower(in value.Value, _ []value.Value) (value.Value, error) {
	s, err := value.ToString(in)
	if err != nil {
		return nil, err
	}
	return asciiMap(s, 'A', 'Z'), nil
}

func trim(in value.Value, _ []value.Value) (value.Value, error) {
	s, err := value.ToString(in)
	if err != nil {
		return nil, err
	}
	return strings.Trim(s, whitespace), nil
}

var htmlEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&#34;", "'", "&#39;")

func escape(in value.Value, _ []value.Value) (value.Value, error) {
	s, err := value.ToString(in)
	if err != nil {
		return nil, err
	}
	return htmlEscaper.Replace(s), nil
}

func replace(in value.Value, args []value.Value) (value.Value, error) {
	s, err := value.ToString(in)
	if err != nil {
		return nil, err
	}
	old, err := value.ToString(args[0])
	if err != nil {
		return nil, err
	}
	repl, err := value.ToString(args[1])
	if err != nil {
		return nil, err
	}
	return strings.ReplaceAll(s, old, repl), nil
}

func length(in value.Value, _ []value.Value) (value.Value, error) {
	switch x := in.(type) {
	case string:
		return int64(utf8.RuneCountInString(x)), nil
	case *value.List:
		return int64(len(x.Items)), nil
	case *value.Dict:
		return int64(x.Len()), nil
	}
	return nil, tplerr.New(tplerr.Type, "length of %T", in)
}

func toInt(in value.Value, _ []value.Value) (value.Value, error) {
	switch x := in.(type) {
	case int64:
		return x, nil
	case float64:
		return int64(x), nil
	case bool:
		if x {
			return int64(1), nil
		}
		return int64(0), nil
	case string:
		return parseInt(x), nil
	}
	return int64(0), nil
}

// parseInt converts a string the way the int filter does: an integer
// literal, else a decimal number truncated toward zero, else 0.
func parseInt(s string) int64 {
	s = strings.Trim(s, whitespace)
	if isIntegerLiteral(s) {
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			return n
		}
	}
	if isDecimalLiteral(s) {
		if f, err := strconv.ParseFloat(s, 64); err == nil {
			return int64(f)
		}
	}
	return 0
}

func digitsAt(s string, i int) int {
	n := 0
	for i+n < len(s) && s[i+n] >= '0' && s[i+n] <= '9' {
		n++
	}
	return n
}

// isIntegerLiteral matches [+-]?[0-9]+.
func isIntegerLiteral(s string) bool {
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i++
	}
	n := digitsAt(s, i)
	return n > 0 && i+n == len(s)
}

// isDecimalLiteral matches [+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?.
func isDecimalLiteral(s string) bool {
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i++
	}
	if n := digitsAt(s, i); n > 0 {
		i += n
		if i < len(s) && s[i] == '.' {
			i++
			i += digitsAt(s, i)
		}
	} else if i < len(s) && s[i] == '.' {
		i++
		n := digitsAt(s, i)
		if n == 0 {
			return false
		}
		i += n
	} else {
		return false
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		n := digitsAt(s, i)
		if n == 0 {
			return false
		}
		i += n
	}
	return i == len(s)
}

func join(in value.Value, args []value.Value) (value.Value, error) {
	items, err := value.Seq(in)
	if err != nil {
		return nil, err
	}
	sep := ""
	if len(args) == 1 {
		if sep, err = value.ToString(args[0]); err != nil {
			return nil, err
		}
	}
	var buf []byte
	for i, e := range items {
		if i > 0 {
			buf = append(buf, sep...)
		}
		if buf, err = value.AppendString(buf, e); err != nil {
			return nil, err
		}
	}
	return string(buf), nil
}

func first(in value.Value, _ []value.Value) (value.Value, error) {
	items, err := value.Seq(in)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return value.Undefined, nil
	}
	return items[0], nil
}

func last(in value.Value, _ []value.Value) (value.Value, error) {
	items, err := value.Seq(in)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return value.Undefined, nil
	}
	return items[len(items)-1], nil
}

func reverse(in value.Value, _ []value.Value) (value.Value, error) {
	if s, ok := in.(string); ok {
		b := make([]byte, 0, len(s))
		for end := len(s); end > 0; {
			_, w := utf8.DecodeLastRuneInString(s[:end])
			b = append(b, s[end-w:end]...)
			end -= w
		}
		return string(b), nil
	}
	items, err := value.Seq(in)
	if err != nil {
		return nil, err
	}
	out := make([]value.Value, len(items))
	for i, e := range items {
		out[len(items)-1-i] = e
	}
	return value.NewList(out), nil
}

func sortFilter(in value.Value, _ []value.Value) (value.Value, error) {
	items, err := value.Seq(in)
	if err != nil {
		return nil, err
	}
	out := make([]value.Value, len(items))
	copy(out, items)
	allStrings, allNumbers := true, true
	for _, e := range out {
		switch e.(type) {
		case string:
			allNumbers = false
		case int64, float64, bool:
			allStrings = false
		default:
			allStrings, allNumbers = false, false
		}
	}
	switch {
	case len(out) == 0:
	case allNumbers:
		sort.SliceStable(out, func(i, j int) bool {
			c, _ := value.Order(out[i], out[j])
			return c < 0
		})
	case allStrings:
		keys := make(map[string]string, len(out))
		for _, e := range out {
			s := e.(string)
			keys[s] = asciiMap(s, 'A', 'Z')
		}
		sort.SliceStable(out, func(i, j int) bool {
			return keys[out[i].(string)] < keys[out[j].(string)]
		})
	default:
		return nil, tplerr.New(tplerr.Type, "sort: elements are not all numbers or all strings")
	}
	return value.NewList(out), nil
}

func defaultFilter(in value.Value, args []value.Value) (value.Value, error) {
	if !value.IsUndefined(in) {
		return in, nil
	}
	if len(args) == 1 {
		return args[0], nil
	}
	return "", nil
}
