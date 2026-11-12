package kbl

import (
	"sort"
	"strconv"
	"strings"

	"buildsys/glob"
	"buildsys/kerr"
)

// Type-set bit flags used to describe builtin parameter types.
const (
	tS = 1 << iota
	tI
	tB
	tL
	tV = tS | tI | tB | tL
)

func typeToken(mask int) string {
	switch mask {
	case tS:
		return "str"
	case tI:
		return "int"
	case tB:
		return "bool"
	case tL:
		return "list"
	case tS | tL:
		return "str|list"
	case tS | tI:
		return "str|int"
	case tS | tI | tB:
		return "str|int|bool"
	}
	return "any"
}

func kindBit(k Kind) int {
	switch k {
	case KStr:
		return tS
	case KInt:
		return tI
	case KBool:
		return tB
	}
	return tL
}

type builtin struct {
	min, max int
	params   []int // type mask per argument; the last repeats for variadics
	fn       func(ev *Evaluator, a []Value) (Value, error)
}

func typeErr(site string, expected, got string) *kerr.Error {
	return kerr.New(kerr.Type, "%s: expected %s, got %s", site, expected, got)
}

func argErr(kind, name, reason string) *kerr.Error {
	return kerr.New(kerr.Arg, "%s %s: %s", kind, name, reason)
}

var builtins map[string]*builtin

func fixed(fn func(ev *Evaluator, a []Value) (Value, error), params ...int) *builtin {
	return &builtin{min: len(params), max: len(params), params: params, fn: fn}
}

// pure wraps a function that cannot fail.
func pure(fn func(a []Value) Value) func(*Evaluator, []Value) (Value, error) {
	return func(_ *Evaluator, a []Value) (Value, error) { return fn(a), nil }
}

func init() {
	builtins = map[string]*builtin{
		"len": fixed(pure(func(a []Value) Value {
			if a[0].K == KStr {
				return Int(int64(len(a[0].S)))
			}
			return Int(int64(len(a[0].L)))
		}), tS|tL),
		"count": fixed(pure(func(a []Value) Value { return Int(int64(len(a[0].L))) }), tL),
		"upper": fixed(pure(func(a []Value) Value { return Str(asciiCase(a[0].S, 'a', 'z', -32)) }), tS),
		"lower": fixed(pure(func(a []Value) Value { return Str(asciiCase(a[0].S, 'A', 'Z', 32)) }), tS),
		"trim":  fixed(pure(func(a []Value) Value { return Str(strings.Trim(a[0].S, " \t\n\r")) }), tS),
		"replace": fixed(func(_ *Evaluator, a []Value) (Value, error) {
			if a[1].S == "" {
				return Value{}, argErr("fn", "replace", "empty pattern")
			}
			return Str(strings.ReplaceAll(a[0].S, a[1].S, a[2].S)), nil
		}, tS, tS, tS),
		"starts_with": fixed(pure(func(a []Value) Value { return Bool(strings.HasPrefix(a[0].S, a[1].S)) }), tS, tS),
		"ends_with":   fixed(pure(func(a []Value) Value { return Bool(strings.HasSuffix(a[0].S, a[1].S)) }), tS, tS),
		"contains":    fixed(pure(func(a []Value) Value { return Bool(strings.Contains(a[0].S, a[1].S)) }), tS, tS),
		"substr": fixed(pure(func(a []Value) Value {
			start, n := clamp(len(a[0].S), a[1].I, a[2].I)
			return Str(a[0].S[start : start+n])
		}), tS, tI, tI),
		"split": fixed(func(_ *Evaluator, a []Value) (Value, error) {
			if a[1].S == "" {
				return Value{}, argErr("fn", "split", "empty separator")
			}
			parts := strings.Split(a[0].S, a[1].S)
			out := make([]Value, len(parts))
			for i, p := range parts {
				out[i] = Str(p)
			}
			return List(out), nil
		}, tS, tS),
		"join": fixed(func(_ *Evaluator, a []Value) (Value, error) {
			parts := make([]string, len(a[0].L))
			for i, e := range a[0].L {
				if e.K != KStr && e.K != KInt {
					return Value{}, typeErr("fn join element "+strconv.Itoa(i), "str|int", e.K.String())
				}
				parts[i] = e.Text()
			}
			return Str(strings.Join(parts, a[1].S)), nil
		}, tL, tS),
		"str": fixed(pure(func(a []Value) Value { return Str(a[0].Text()) }), tS|tI|tB),
		"int": fixed(func(_ *Evaluator, a []Value) (Value, error) {
			if a[0].K == KInt {
				return a[0], nil
			}
			s := a[0].S
			digits := strings.TrimPrefix(s, "-")
			ok := digits != ""
			for i := 0; i < len(digits); i++ {
				if digits[i] < '0' || digits[i] > '9' {
					ok = false
				}
			}
			if ok {
				if n, err := strconv.ParseInt(s, 10, 64); err == nil {
					return Int(n), nil
				}
			}
			return Value{}, argErr("fn", "int", "bad integer")
		}, tS|tI),
		"dirname": fixed(pure(func(a []Value) Value {
			if i := strings.LastIndexByte(a[0].S, '/'); i >= 0 {
				return Str(a[0].S[:i])
			}
			return Str("")
		}), tS),
		"basename": fixed(pure(func(a []Value) Value { return Str(basename(a[0].S)) }), tS),
		"stem": fixed(pure(func(a []Value) Value {
			s, _ := splitExt(basename(a[0].S))
			return Str(s)
		}), tS),
		"ext": fixed(pure(func(a []Value) Value {
			_, e := splitExt(basename(a[0].S))
			return Str(e)
		}), tS),
		"pathjoin": {min: 1, max: 8, params: []int{tS}, fn: pure(func(a []Value) Value {
			parts := make([]string, 0, len(a))
			for _, v := range a {
				if v.S != "" {
					parts = append(parts, v.S)
				}
			}
			return Str(strings.Join(parts, "/"))
		})},
		"map": fixed(func(_ *Evaluator, a []Value) (Value, error) {
			out := make([]Value, len(a[0].L))
			for i, e := range a[0].L {
				if e.K != KStr {
					return Value{}, typeErr("fn map element "+strconv.Itoa(i), "str", e.K.String())
				}
				out[i] = Str(mapPattern(a[1].S, e.S))
			}
			return List(out), nil
		}, tL, tS),
		"filter": fixed(func(_ *Evaluator, a []Value) (Value, error) { return filter(a, true) }, tL, tS),
		"reject": fixed(func(_ *Evaluator, a []Value) (Value, error) { return filter(a, false) }, tL, tS),
		"sort": fixed(pure(func(a []Value) Value {
			out := append([]Value(nil), a[0].L...)
			sort.SliceStable(out, func(i, j int) bool { return Compare(out[i], out[j]) < 0 })
			return List(out)
		}), tL),
		"uniq": fixed(pure(func(a []Value) Value {
			seen := make(map[string]struct{}, len(a[0].L))
			out := make([]Value, 0, len(a[0].L))
			var b strings.Builder
			for _, e := range a[0].L {
				b.Reset()
				e.key(&b)
				k := b.String()
				if _, ok := seen[k]; ok {
					continue
				}
				seen[k] = struct{}{}
				out = append(out, e)
			}
			return List(out)
		}), tL),
		"reverse": fixed(pure(func(a []Value) Value {
			n := len(a[0].L)
			out := make([]Value, n)
			for i, e := range a[0].L {
				out[n-1-i] = e
			}
			return List(out)
		}), tL),
		"first": fixed(func(_ *Evaluator, a []Value) (Value, error) {
			if len(a[0].L) == 0 {
				return Value{}, argErr("fn", "first", "empty list")
			}
			return a[0].L[0], nil
		}, tL),
		"last": fixed(func(_ *Evaluator, a []Value) (Value, error) {
			if len(a[0].L) == 0 {
				return Value{}, argErr("fn", "last", "empty list")
			}
			return a[0].L[len(a[0].L)-1], nil
		}, tL),
		"slice": fixed(pure(func(a []Value) Value {
			start, n := clamp(len(a[0].L), a[1].I, a[2].I)
			return List(append([]Value(nil), a[0].L[start:start+n]...))
		}), tL, tI, tI),
		"has": fixed(pure(func(a []Value) Value {
			for _, e := range a[0].L {
				if Equal(e, a[1]) {
					return Bool(true)
				}
			}
			return Bool(false)
		}), tL, tV),
		"indexof": fixed(pure(func(a []Value) Value {
			for i, e := range a[0].L {
				if Equal(e, a[1]) {
					return Int(int64(i))
				}
			}
			return Int(-1)
		}), tL, tV),
		"range": fixed(func(_ *Evaluator, a []Value) (Value, error) {
			if a[0].I < 0 {
				return Value{}, argErr("fn", "range", "negative")
			}
			out := make([]Value, a[0].I)
			for i := range out {
				out[i] = Int(int64(i))
			}
			return List(out), nil
		}, tI),
		"sum": fixed(func(_ *Evaluator, a []Value) (Value, error) {
			var s int64
			for i, e := range a[0].L {
				if e.K != KInt {
					return Value{}, typeErr("fn sum element "+strconv.Itoa(i), "int", e.K.String())
				}
				s += e.I
			}
			return Int(s), nil
		}, tL),
		"flatten": fixed(pure(func(a []Value) Value {
			out := make([]Value, 0, len(a[0].L))
			for _, e := range a[0].L {
				if e.K == KList {
					out = append(out, e.L...)
				} else {
					out = append(out, e)
				}
			}
			return List(out)
		}), tL),
		"zip": fixed(pure(func(a []Value) Value {
			n := min(len(a[0].L), len(a[1].L))
			out := make([]Value, n)
			for i := 0; i < n; i++ {
				out[i] = List([]Value{a[0].L[i], a[1].L[i]})
			}
			return List(out)
		}), tL, tL),
		"is_str":  fixed(pure(func(a []Value) Value { return Bool(a[0].K == KStr) }), tV),
		"is_int":  fixed(pure(func(a []Value) Value { return Bool(a[0].K == KInt) }), tV),
		"is_bool": fixed(pure(func(a []Value) Value { return Bool(a[0].K == KBool) }), tV),
		"is_list": fixed(pure(func(a []Value) Value { return Bool(a[0].K == KList) }), tV),
		"glob": fixed(func(ev *Evaluator, a []Value) (Value, error) {
			pat, err := glob.Compile(a[0].S)
			if err != nil {
				return Value{}, argErr("fn", "glob", "bad pattern")
			}
			var out []Value
			for _, p := range ev.fs.WithPrefix(pat.LiteralPrefix()) {
				if pat.Match(p) {
					out = append(out, Str(p))
				}
			}
			return List(out), nil
		}, tS),
	}
}

func filter(a []Value, keep bool) (Value, error) {
	name := "reject"
	if keep {
		name = "filter"
	}
	pat, err := glob.Compile(a[1].S)
	if err != nil {
		return Value{}, argErr("fn", name, "bad pattern")
	}
	out := make([]Value, 0, len(a[0].L))
	for i, e := range a[0].L {
		if e.K != KStr {
			return Value{}, typeErr("fn "+name+" element "+strconv.Itoa(i), "str", e.K.String())
		}
		if pat.Match(e.S) == keep {
			out = append(out, e)
		}
	}
	return List(out), nil
}

// clamp applies the substr/slice clamping rules.
func clamp(n int, start, count int64) (int, int) {
	s := start
	if s < 0 {
		s += int64(n)
	}
	if s < 0 {
		s = 0
	}
	if s > int64(n) {
		s = int64(n)
	}
	c := count
	if c < 0 {
		c = 0
	}
	if c > int64(n)-s {
		c = int64(n) - s
	}
	return int(s), int(c)
}

func basename(s string) string {
	if i := strings.LastIndexByte(s, '/'); i >= 0 {
		return s[i+1:]
	}
	return s
}

// splitExt splits a base name at its last dot that is not at index 0.
func splitExt(b string) (stem, ext string) {
	if i := strings.LastIndexByte(b, '.'); i > 0 {
		return b[:i], b[i:]
	}
	return b, ""
}

func asciiCase(s string, lo, hi byte, delta int) string {
	var b []byte
	for i := 0; i < len(s); i++ {
		if c := s[i]; c >= lo && c <= hi {
			if b == nil {
				b = []byte(s)
			}
			b[i] = byte(int(c) + delta)
		}
	}
	if b == nil {
		return s
	}
	return string(b)
}

// mapPattern expands a map pattern for one element.
func mapPattern(pat, elem string) string {
	var b strings.Builder
	for i := 0; i < len(pat); i++ {
		if pat[i] != '%' {
			b.WriteByte(pat[i])
		} else if i+1 < len(pat) && pat[i+1] == '%' {
			b.WriteByte('%')
			i++
		} else {
			b.WriteString(elem)
		}
	}
	return b.String()
}
