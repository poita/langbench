package kbl

import (
	"sort"
	"strconv"
	"strings"

	"buildsys/glob"
	"buildsys/kerr"
)

// argType is a set of accepted value kinds for a built-in's argument.
type argType struct {
	kinds [4]bool
	token string
}

func (t argType) accepts(v Value) bool { return t.kinds[v.K] }
func (t argType) expected() string     { return t.token }

var (
	tS   = argType{[4]bool{KStr: true}, "str"}
	tI   = argType{[4]bool{KInt: true}, "int"}
	tL   = argType{[4]bool{KList: true}, "list"}
	tV   = argType{[4]bool{true, true, true, true}, "any"}
	tSL  = argType{[4]bool{KStr: true, KList: true}, "str|list"}
	tSI  = argType{[4]bool{KStr: true, KInt: true}, "str|int"}
	tSIB = argType{[4]bool{KBool: true, KInt: true, KStr: true}, "str|int|bool"}
)

type builtin struct {
	min, max int
	types    []argType // type of argument i is types[min(i, len-1)]
	run      func(it *interp, a []Value) (Value, error)
}

func fixed(types []argType, run func(it *interp, a []Value) (Value, error)) *builtin {
	return &builtin{min: len(types), max: len(types), types: types, run: run}
}

func argErr(name, reason string) error {
	return kerr.New(kerr.Arg, "fn %s: %s", name, reason)
}

func strs(ss []string) Value {
	l := make([]Value, len(ss))
	for i, s := range ss {
		l[i] = vStr(s)
	}
	return vList(l)
}

func clamp(start, count, n int64) (int64, int64) {
	if start < 0 {
		start += n
	}
	start = max(0, min(start, n))
	count = max(0, min(count, n-start))
	return start, count
}

func isTrim(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

func lastSlash(s string) int { return strings.LastIndexByte(s, '/') }

func baseName(p string) string { return p[lastSlash(p)+1:] }

// splitExt returns the stem and extension of a path's basename.
func splitExt(p string) (string, string) {
	b := baseName(p)
	for i := len(b) - 1; i > 0; i-- {
		if b[i] == '.' {
			return b[:i], b[i:]
		}
	}
	return b, ""
}

func mapOver(a []Value, f func(Value) Value) Value {
	out := make([]Value, len(a))
	for i, v := range a {
		out[i] = f(v)
	}
	return vList(out)
}

func isKind(k Kind) *builtin {
	return fixed([]argType{tV}, func(_ *interp, a []Value) (Value, error) { return vBool(a[0].K == k), nil })
}

// filterList implements filter (keep == true) and reject (keep == false).
func filterList(name string, keep bool) *builtin {
	return fixed([]argType{tL, tS}, func(_ *interp, a []Value) (Value, error) {
		pat, err := glob.Compile(a[1].S)
		if err != nil {
			return Value{}, argErr(name, "bad pattern")
		}
		var out []Value
		for i, e := range a[0].L {
			if e.K != KStr {
				return Value{}, kerr.NewType("fn "+name+" element "+strconv.Itoa(i), "str", e.K.String())
			}
			if pat.Match(e.S) == keep {
				out = append(out, e)
			}
		}
		return vList(out), nil
	})
}

var builtins map[string]*builtin

func init() {
	builtins = map[string]*builtin{
		"len": fixed([]argType{tSL}, func(_ *interp, a []Value) (Value, error) {
			if a[0].K == KStr {
				return vInt(int64(len(a[0].S))), nil
			}
			return vInt(int64(len(a[0].L))), nil
		}),
		"count": fixed([]argType{tL}, func(_ *interp, a []Value) (Value, error) {
			return vInt(int64(len(a[0].L))), nil
		}),
		"upper": fixed([]argType{tS}, func(_ *interp, a []Value) (Value, error) {
			b := []byte(a[0].S)
			for i, c := range b {
				if c >= 'a' && c <= 'z' {
					b[i] = c - 32
				}
			}
			return vStr(string(b)), nil
		}),
		"lower": fixed([]argType{tS}, func(_ *interp, a []Value) (Value, error) {
			b := []byte(a[0].S)
			for i, c := range b {
				if c >= 'A' && c <= 'Z' {
					b[i] = c + 32
				}
			}
			return vStr(string(b)), nil
		}),
		"trim": fixed([]argType{tS}, func(_ *interp, a []Value) (Value, error) {
			s := a[0].S
			i, j := 0, len(s)
			for i < j && isTrim(s[i]) {
				i++
			}
			for j > i && isTrim(s[j-1]) {
				j--
			}
			return vStr(s[i:j]), nil
		}),
		"replace": fixed([]argType{tS, tS, tS}, func(_ *interp, a []Value) (Value, error) {
			if a[1].S == "" {
				return Value{}, argErr("replace", "empty pattern")
			}
			return vStr(strings.ReplaceAll(a[0].S, a[1].S, a[2].S)), nil
		}),
		"starts_with": fixed([]argType{tS, tS}, func(_ *interp, a []Value) (Value, error) {
			return vBool(strings.HasPrefix(a[0].S, a[1].S)), nil
		}),
		"ends_with": fixed([]argType{tS, tS}, func(_ *interp, a []Value) (Value, error) {
			return vBool(strings.HasSuffix(a[0].S, a[1].S)), nil
		}),
		"contains": fixed([]argType{tS, tS}, func(_ *interp, a []Value) (Value, error) {
			return vBool(strings.Contains(a[0].S, a[1].S)), nil
		}),
		"substr": fixed([]argType{tS, tI, tI}, func(_ *interp, a []Value) (Value, error) {
			start, count := clamp(a[1].I, a[2].I, int64(len(a[0].S)))
			return vStr(a[0].S[start : start+count]), nil
		}),
		"split": fixed([]argType{tS, tS}, func(_ *interp, a []Value) (Value, error) {
			if a[1].S == "" {
				return Value{}, argErr("split", "empty separator")
			}
			return strs(strings.Split(a[0].S, a[1].S)), nil
		}),
		"join": fixed([]argType{tL, tS}, func(_ *interp, a []Value) (Value, error) {
			var b strings.Builder
			for i, e := range a[0].L {
				if i > 0 {
					b.WriteString(a[1].S)
				}
				switch e.K {
				case KStr:
					b.WriteString(e.S)
				case KInt:
					b.WriteString(strconv.FormatInt(e.I, 10))
				default:
					return Value{}, kerr.NewType("fn join element "+strconv.Itoa(i), "str|int", e.K.String())
				}
			}
			return vStr(b.String()), nil
		}),
		"str": fixed([]argType{tSIB}, func(_ *interp, a []Value) (Value, error) {
			var b strings.Builder
			if err := writeInterp(&b, a[0]); err != nil {
				return Value{}, err
			}
			return vStr(b.String()), nil
		}),
		"int": fixed([]argType{tSI}, func(_ *interp, a []Value) (Value, error) {
			if a[0].K == KInt {
				return a[0], nil
			}
			s := a[0].S
			digits := strings.TrimPrefix(s, "-")
			ok := digits != ""
			for i := 0; i < len(digits); i++ {
				if !isDigit(digits[i]) {
					ok = false
				}
			}
			if ok {
				if n, err := strconv.ParseInt(s, 10, 64); err == nil {
					return vInt(n), nil
				}
			}
			return Value{}, argErr("int", "bad integer")
		}),
		"dirname": fixed([]argType{tS}, func(_ *interp, a []Value) (Value, error) {
			i := lastSlash(a[0].S)
			if i < 0 {
				return vStr(""), nil
			}
			return vStr(a[0].S[:i]), nil
		}),
		"basename": fixed([]argType{tS}, func(_ *interp, a []Value) (Value, error) {
			return vStr(baseName(a[0].S)), nil
		}),
		"stem": fixed([]argType{tS}, func(_ *interp, a []Value) (Value, error) {
			s, _ := splitExt(a[0].S)
			return vStr(s), nil
		}),
		"ext": fixed([]argType{tS}, func(_ *interp, a []Value) (Value, error) {
			_, e := splitExt(a[0].S)
			return vStr(e), nil
		}),
		"pathjoin": {min: 1, max: 8, types: []argType{tS}, run: func(_ *interp, a []Value) (Value, error) {
			parts := make([]string, 0, len(a))
			for _, v := range a {
				if v.S != "" {
					parts = append(parts, v.S)
				}
			}
			return vStr(strings.Join(parts, "/")), nil
		}},
		"map": fixed([]argType{tL, tS}, func(_ *interp, a []Value) (Value, error) {
			pat := a[1].S
			out := make([]Value, len(a[0].L))
			for i, e := range a[0].L {
				if e.K != KStr {
					return Value{}, kerr.NewType("fn map element "+strconv.Itoa(i), "str", e.K.String())
				}
				var b strings.Builder
				for j := 0; j < len(pat); j++ {
					if pat[j] != '%' {
						b.WriteByte(pat[j])
					} else if j+1 < len(pat) && pat[j+1] == '%' {
						b.WriteByte('%')
						j++
					} else {
						b.WriteString(e.S)
					}
				}
				out[i] = vStr(b.String())
			}
			return vList(out), nil
		}),
		"filter": filterList("filter", true),
		"reject": filterList("reject", false),
		"sort": fixed([]argType{tL}, func(_ *interp, a []Value) (Value, error) {
			out := append([]Value(nil), a[0].L...)
			sort.SliceStable(out, func(i, j int) bool { return compare(out[i], out[j]) < 0 })
			return vList(out), nil
		}),
		"uniq": fixed([]argType{tL}, func(_ *interp, a []Value) (Value, error) {
			seen := make(map[string]struct{}, len(a[0].L))
			out := make([]Value, 0, len(a[0].L))
			var b strings.Builder
			for _, e := range a[0].L {
				b.Reset()
				e.key(&b)
				k := b.String()
				if _, dup := seen[k]; !dup {
					seen[k] = struct{}{}
					out = append(out, e)
				}
			}
			return vList(out), nil
		}),
		"reverse": fixed([]argType{tL}, func(_ *interp, a []Value) (Value, error) {
			n := len(a[0].L)
			out := make([]Value, n)
			for i, e := range a[0].L {
				out[n-1-i] = e
			}
			return vList(out), nil
		}),
		"first": fixed([]argType{tL}, func(_ *interp, a []Value) (Value, error) {
			if len(a[0].L) == 0 {
				return Value{}, argErr("first", "empty list")
			}
			return a[0].L[0], nil
		}),
		"last": fixed([]argType{tL}, func(_ *interp, a []Value) (Value, error) {
			if len(a[0].L) == 0 {
				return Value{}, argErr("last", "empty list")
			}
			return a[0].L[len(a[0].L)-1], nil
		}),
		"slice": fixed([]argType{tL, tI, tI}, func(_ *interp, a []Value) (Value, error) {
			start, count := clamp(a[1].I, a[2].I, int64(len(a[0].L)))
			return vList(append([]Value(nil), a[0].L[start:start+count]...)), nil
		}),
		"has": fixed([]argType{tL, tV}, func(_ *interp, a []Value) (Value, error) {
			for _, e := range a[0].L {
				if equal(e, a[1]) {
					return vBool(true), nil
				}
			}
			return vBool(false), nil
		}),
		"indexof": fixed([]argType{tL, tV}, func(_ *interp, a []Value) (Value, error) {
			for i, e := range a[0].L {
				if equal(e, a[1]) {
					return vInt(int64(i)), nil
				}
			}
			return vInt(-1), nil
		}),
		"range": fixed([]argType{tI}, func(_ *interp, a []Value) (Value, error) {
			if a[0].I < 0 {
				return Value{}, argErr("range", "negative")
			}
			out := make([]Value, a[0].I)
			for i := range out {
				out[i] = vInt(int64(i))
			}
			return vList(out), nil
		}),
		"sum": fixed([]argType{tL}, func(_ *interp, a []Value) (Value, error) {
			var total int64
			for i, e := range a[0].L {
				if e.K != KInt {
					return Value{}, kerr.NewType("fn sum element "+strconv.Itoa(i), "int", e.K.String())
				}
				total += e.I
			}
			return vInt(total), nil
		}),
		"flatten": fixed([]argType{tL}, func(_ *interp, a []Value) (Value, error) {
			var out []Value
			for _, e := range a[0].L {
				if e.K == KList {
					out = append(out, e.L...)
				} else {
					out = append(out, e)
				}
			}
			return vList(out), nil
		}),
		"zip": fixed([]argType{tL, tL}, func(_ *interp, a []Value) (Value, error) {
			n := min(len(a[0].L), len(a[1].L))
			out := make([]Value, n)
			for i := 0; i < n; i++ {
				out[i] = vList([]Value{a[0].L[i], a[1].L[i]})
			}
			return vList(out), nil
		}),
		"is_str":  isKind(KStr),
		"is_int":  isKind(KInt),
		"is_bool": isKind(KBool),
		"is_list": isKind(KList),
		"glob": fixed([]argType{tS}, func(it *interp, a []Value) (Value, error) {
			pat, err := glob.Compile(a[0].S)
			if err != nil {
				return Value{}, argErr("glob", "bad pattern")
			}
			var out []string
			for _, p := range it.fs.GlobCandidates(glob.LiteralPrefix(a[0].S)) {
				if pat.Match(p) {
					out = append(out, p)
				}
			}
			return strs(out), nil
		}),
	}
}
