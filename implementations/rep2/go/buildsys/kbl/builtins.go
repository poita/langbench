package kbl

import (
	"bytes"
	"sort"
	"strconv"
	"strings"

	"kiln/errs"
	"kiln/glob"
)

// typeMask is a set of Kinds an argument may have.
type typeMask uint8

const (
	mB   = typeMask(1) << KBool
	mI   = typeMask(1) << KInt
	mS   = typeMask(1) << KStr
	mL   = typeMask(1) << KList
	mAny = mB | mI | mS | mL
)

func (m typeMask) has(k Kind) bool { return m&(1<<k) != 0 }

// name renders the mask as the type token of the specification.
func (m typeMask) name() string {
	var parts []string
	for _, k := range []Kind{KStr, KInt, KBool, KList} {
		if m.has(k) {
			parts = append(parts, k.String())
		}
	}
	return strings.Join(parts, "|")
}

type builtin struct {
	name     string
	min, max int
	params   []typeMask // the last entry applies to all further arguments
	run      func(it *Interp, a []Value) (Value, *errs.Error)
}

var builtins map[string]*builtin

// BuiltinNames returns the sorted names of all built-in functions.
func BuiltinNames() []string {
	out := make([]string, 0, len(builtins))
	for n := range builtins {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

func typeErr(site string, m typeMask, got Kind) *errs.Error {
	return errs.New(errs.Type, "%s: expected %s, got %s", site, m.name(), got)
}

func argErr(kind, name, reason string) *errs.Error {
	return errs.New(errs.Arg, "%s %s: %s", kind, name, reason)
}

func reg(name string, params []typeMask, run func(it *Interp, a []Value) (Value, *errs.Error)) {
	builtins[name] = &builtin{name: name, min: len(params), max: len(params), params: params, run: run}
}

// pure registers a function that needs no interpreter state.
func pure(name string, params []typeMask, f func(a []Value) (Value, *errs.Error)) {
	reg(name, params, func(_ *Interp, a []Value) (Value, *errs.Error) { return f(a) })
}

func ps(m ...typeMask) []typeMask { return m }

func strs(xs []string) Value {
	l := make([]Value, len(xs))
	for i, s := range xs {
		l[i] = strVal(s)
	}
	return listVal(l)
}

func clampRange(n int, start, count int64) (int, int) {
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

func lastSlash(s string) int { return strings.LastIndexByte(s, '/') }

func stemExt(p string) (stem, ext string) {
	b := p[lastSlash(p)+1:]
	for i := len(b) - 1; i > 0; i-- {
		if b[i] == '.' {
			return b[:i], b[i:]
		}
	}
	return b, ""
}

func parseIntStr(s string) (int64, bool) {
	t := s
	if strings.HasPrefix(t, "-") {
		t = t[1:]
	}
	if t == "" {
		return 0, false
	}
	for i := 0; i < len(t); i++ {
		if !isDigit(t[i]) {
			return 0, false
		}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}

func compileGlob(fn, pat string) (*glob.Pattern, *errs.Error) {
	p, err := glob.Compile(pat)
	if err != nil {
		return nil, argErr("fn", fn, "bad pattern")
	}
	return p, nil
}

func filterList(name string, keep bool) func(a []Value) (Value, *errs.Error) {
	return func(a []Value) (Value, *errs.Error) {
		pat, err := compileGlob(name, a[1].S)
		if err != nil {
			return Value{}, err
		}
		out := make([]Value, 0, len(a[0].L))
		for i, e := range a[0].L {
			if e.K != KStr {
				return Value{}, typeErr("fn "+name+" element "+strconv.Itoa(i), mS, e.K)
			}
			if pat.Match(e.S) == keep {
				out = append(out, e)
			}
		}
		return listVal(out), nil
	}
}

func init() {
	builtins = make(map[string]*builtin, 40)
	S, I, B, L := mS, mI, mB, mL

	pure("len", ps(S|L), func(a []Value) (Value, *errs.Error) {
		if a[0].K == KStr {
			return intVal(int64(len(a[0].S))), nil
		}
		return intVal(int64(len(a[0].L))), nil
	})
	pure("count", ps(L), func(a []Value) (Value, *errs.Error) { return intVal(int64(len(a[0].L))), nil })
	pure("upper", ps(S), func(a []Value) (Value, *errs.Error) {
		b := []byte(a[0].S)
		for i, c := range b {
			if c >= 'a' && c <= 'z' {
				b[i] = c - 32
			}
		}
		return strVal(string(b)), nil
	})
	pure("lower", ps(S), func(a []Value) (Value, *errs.Error) {
		b := []byte(a[0].S)
		for i, c := range b {
			if c >= 'A' && c <= 'Z' {
				b[i] = c + 32
			}
		}
		return strVal(string(b)), nil
	})
	pure("trim", ps(S), func(a []Value) (Value, *errs.Error) {
		return strVal(strings.Trim(a[0].S, " \t\n\r")), nil
	})
	pure("replace", ps(S, S, S), func(a []Value) (Value, *errs.Error) {
		if a[1].S == "" {
			return Value{}, argErr("fn", "replace", "empty pattern")
		}
		return strVal(strings.ReplaceAll(a[0].S, a[1].S, a[2].S)), nil
	})
	pure("starts_with", ps(S, S), func(a []Value) (Value, *errs.Error) {
		return boolVal(strings.HasPrefix(a[0].S, a[1].S)), nil
	})
	pure("ends_with", ps(S, S), func(a []Value) (Value, *errs.Error) {
		return boolVal(strings.HasSuffix(a[0].S, a[1].S)), nil
	})
	pure("contains", ps(S, S), func(a []Value) (Value, *errs.Error) {
		return boolVal(strings.Contains(a[0].S, a[1].S)), nil
	})
	pure("substr", ps(S, I, I), func(a []Value) (Value, *errs.Error) {
		s, c := clampRange(len(a[0].S), a[1].I, a[2].I)
		return strVal(a[0].S[s : s+c]), nil
	})
	pure("split", ps(S, S), func(a []Value) (Value, *errs.Error) {
		if a[1].S == "" {
			return Value{}, argErr("fn", "split", "empty separator")
		}
		return strs(strings.Split(a[0].S, a[1].S)), nil
	})
	pure("join", ps(L, S), func(a []Value) (Value, *errs.Error) {
		var sb strings.Builder
		for i, e := range a[0].L {
			if e.K != KStr && e.K != KInt {
				return Value{}, typeErr("fn join element "+strconv.Itoa(i), mS|mI, e.K)
			}
			if i > 0 {
				sb.WriteString(a[1].S)
			}
			sb.WriteString(e.text())
		}
		return strVal(sb.String()), nil
	})
	pure("str", ps(S|I|B), func(a []Value) (Value, *errs.Error) { return strVal(a[0].text()), nil })
	pure("int", ps(S|I), func(a []Value) (Value, *errs.Error) {
		if a[0].K == KInt {
			return a[0], nil
		}
		n, ok := parseIntStr(a[0].S)
		if !ok {
			return Value{}, argErr("fn", "int", "bad integer")
		}
		return intVal(n), nil
	})
	pure("dirname", ps(S), func(a []Value) (Value, *errs.Error) {
		i := lastSlash(a[0].S)
		if i < 0 {
			return strVal(""), nil
		}
		return strVal(a[0].S[:i]), nil
	})
	pure("basename", ps(S), func(a []Value) (Value, *errs.Error) {
		return strVal(a[0].S[lastSlash(a[0].S)+1:]), nil
	})
	pure("stem", ps(S), func(a []Value) (Value, *errs.Error) {
		s, _ := stemExt(a[0].S)
		return strVal(s), nil
	})
	pure("ext", ps(S), func(a []Value) (Value, *errs.Error) {
		_, e := stemExt(a[0].S)
		return strVal(e), nil
	})
	builtins["pathjoin"] = &builtin{name: "pathjoin", min: 1, max: 8, params: ps(S),
		run: func(_ *Interp, a []Value) (Value, *errs.Error) {
			parts := make([]string, 0, len(a))
			for _, v := range a {
				if v.S != "" {
					parts = append(parts, v.S)
				}
			}
			return strVal(strings.Join(parts, "/")), nil
		}}
	pure("map", ps(L, S), func(a []Value) (Value, *errs.Error) {
		pat := a[1].S
		out := make([]Value, len(a[0].L))
		for i, e := range a[0].L {
			if e.K != KStr {
				return Value{}, typeErr("fn map element "+strconv.Itoa(i), mS, e.K)
			}
			var sb strings.Builder
			for j := 0; j < len(pat); j++ {
				if pat[j] != '%' {
					sb.WriteByte(pat[j])
				} else if j+1 < len(pat) && pat[j+1] == '%' {
					sb.WriteByte('%')
					j++
				} else {
					sb.WriteString(e.S)
				}
			}
			out[i] = strVal(sb.String())
		}
		return listVal(out), nil
	})
	pure("filter", ps(L, S), filterList("filter", true))
	pure("reject", ps(L, S), filterList("reject", false))
	pure("sort", ps(L), func(a []Value) (Value, *errs.Error) {
		out := append([]Value(nil), a[0].L...)
		sort.SliceStable(out, func(i, j int) bool { return Compare(out[i], out[j]) < 0 })
		return listVal(out), nil
	})
	pure("uniq", ps(L), func(a []Value) (Value, *errs.Error) {
		seen := make(map[string]struct{}, len(a[0].L))
		out := make([]Value, 0, len(a[0].L))
		var kb bytes.Buffer
		for _, e := range a[0].L {
			kb.Reset()
			e.key(&kb)
			if _, dup := seen[kb.String()]; dup {
				continue
			}
			seen[kb.String()] = struct{}{}
			out = append(out, e)
		}
		return listVal(out), nil
	})
	pure("reverse", ps(L), func(a []Value) (Value, *errs.Error) {
		n := len(a[0].L)
		out := make([]Value, n)
		for i, e := range a[0].L {
			out[n-1-i] = e
		}
		return listVal(out), nil
	})
	pure("first", ps(L), func(a []Value) (Value, *errs.Error) {
		if len(a[0].L) == 0 {
			return Value{}, argErr("fn", "first", "empty list")
		}
		return a[0].L[0], nil
	})
	pure("last", ps(L), func(a []Value) (Value, *errs.Error) {
		if len(a[0].L) == 0 {
			return Value{}, argErr("fn", "last", "empty list")
		}
		return a[0].L[len(a[0].L)-1], nil
	})
	pure("slice", ps(L, I, I), func(a []Value) (Value, *errs.Error) {
		s, c := clampRange(len(a[0].L), a[1].I, a[2].I)
		return listVal(a[0].L[s : s+c : s+c]), nil
	})
	pure("has", ps(L, mAny), func(a []Value) (Value, *errs.Error) {
		for _, e := range a[0].L {
			if Equal(e, a[1]) {
				return boolVal(true), nil
			}
		}
		return boolVal(false), nil
	})
	pure("indexof", ps(L, mAny), func(a []Value) (Value, *errs.Error) {
		for i, e := range a[0].L {
			if Equal(e, a[1]) {
				return intVal(int64(i)), nil
			}
		}
		return intVal(-1), nil
	})
	pure("range", ps(I), func(a []Value) (Value, *errs.Error) {
		if a[0].I < 0 {
			return Value{}, argErr("fn", "range", "negative")
		}
		out := make([]Value, a[0].I)
		for i := range out {
			out[i] = intVal(int64(i))
		}
		return listVal(out), nil
	})
	pure("sum", ps(L), func(a []Value) (Value, *errs.Error) {
		var t int64
		for i, e := range a[0].L {
			if e.K != KInt {
				return Value{}, typeErr("fn sum element "+strconv.Itoa(i), mI, e.K)
			}
			t += e.I
		}
		return intVal(t), nil
	})
	pure("flatten", ps(L), func(a []Value) (Value, *errs.Error) {
		var out []Value
		for _, e := range a[0].L {
			if e.K == KList {
				out = append(out, e.L...)
			} else {
				out = append(out, e)
			}
		}
		if out == nil {
			out = []Value{}
		}
		return listVal(out), nil
	})
	pure("zip", ps(L, L), func(a []Value) (Value, *errs.Error) {
		n := min(len(a[0].L), len(a[1].L))
		out := make([]Value, n)
		for i := 0; i < n; i++ {
			out[i] = listVal([]Value{a[0].L[i], a[1].L[i]})
		}
		return listVal(out), nil
	})
	for _, k := range []Kind{KStr, KInt, KBool, KList} {
		k := k
		pure("is_"+k.String(), ps(mAny), func(a []Value) (Value, *errs.Error) { return boolVal(a[0].K == k), nil })
	}
	reg("glob", ps(S), func(it *Interp, a []Value) (Value, *errs.Error) {
		pat, err := compileGlob("glob", a[0].S)
		if err != nil {
			return Value{}, err
		}
		cands := it.fs.GlobCandidates(pat.LiteralPrefix())
		out := []Value{}
		for _, p := range cands {
			if pat.Match(p) {
				out = append(out, strVal(p))
			}
		}
		return listVal(out), nil
	})
}
