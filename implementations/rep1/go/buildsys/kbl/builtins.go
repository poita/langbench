package kbl

import (
	"sort"
	"strconv"
	"strings"

	"buildsys/glob"
	"buildsys/kilnerr"
)

// builtin describes one built-in function. types holds the accepted type
// token per argument; for variadic functions the first entry applies to all
// arguments beyond the end of the slice.
type builtin struct {
	minArgs, maxArgs int
	types            []string
	fn               func(ip *Interp, a []Value) Value
}

var builtins map[string]*builtin

func fixed(types []string, fn func(ip *Interp, a []Value) Value) *builtin {
	return &builtin{minArgs: len(types), maxArgs: len(types), types: types, fn: fn}
}

func ts(t ...string) []string { return t }

func init() {
	b := map[string]*builtin{}
	b["len"] = fixed(ts("str|list"), func(_ *Interp, a []Value) Value {
		if a[0].K == KStr {
			return vInt(int64(len(a[0].S)))
		}
		return vInt(int64(len(a[0].L)))
	})
	b["count"] = fixed(ts("list"), func(_ *Interp, a []Value) Value { return vInt(int64(len(a[0].L))) })
	b["upper"] = fixed(ts("str"), func(_ *Interp, a []Value) Value {
		return vStr(string(asciiMap([]byte(a[0].S), 'a', 'z', 'A'-'a')))
	})
	b["lower"] = fixed(ts("str"), func(_ *Interp, a []Value) Value {
		return vStr(string(asciiMap([]byte(a[0].S), 'A', 'Z', 'a'-'A')))
	})
	b["trim"] = fixed(ts("str"), func(_ *Interp, a []Value) Value {
		return vStr(strings.Trim(a[0].S, " \t\n\r"))
	})
	b["replace"] = fixed(ts("str", "str", "str"), func(_ *Interp, a []Value) Value {
		if a[1].S == "" {
			raise(kilnerr.Arg, "fn replace: empty pattern")
		}
		return vStr(strings.ReplaceAll(a[0].S, a[1].S, a[2].S))
	})
	b["starts_with"] = fixed(ts("str", "str"), func(_ *Interp, a []Value) Value {
		return vBool(strings.HasPrefix(a[0].S, a[1].S))
	})
	b["ends_with"] = fixed(ts("str", "str"), func(_ *Interp, a []Value) Value {
		return vBool(strings.HasSuffix(a[0].S, a[1].S))
	})
	b["contains"] = fixed(ts("str", "str"), func(_ *Interp, a []Value) Value {
		return vBool(strings.Contains(a[0].S, a[1].S))
	})
	b["substr"] = fixed(ts("str", "int", "int"), func(_ *Interp, a []Value) Value {
		s, n := clamp(a[1].I, a[2].I, len(a[0].S))
		return vStr(a[0].S[s : s+n])
	})
	b["split"] = fixed(ts("str", "str"), func(_ *Interp, a []Value) Value {
		if a[1].S == "" {
			raise(kilnerr.Arg, "fn split: empty separator")
		}
		parts := strings.Split(a[0].S, a[1].S)
		out := make([]Value, len(parts))
		for i, p := range parts {
			out[i] = vStr(p)
		}
		return vList(out)
	})
	b["join"] = fixed(ts("list", "str"), func(_ *Interp, a []Value) Value {
		var sb strings.Builder
		for i, e := range a[0].L {
			switch e.K {
			case KStr:
				if i > 0 {
					sb.WriteString(a[1].S)
				}
				sb.WriteString(e.S)
			case KInt:
				if i > 0 {
					sb.WriteString(a[1].S)
				}
				sb.WriteString(strconv.FormatInt(e.I, 10))
			default:
				typeErr("fn join element "+itoa(i), "str|int", e.K)
			}
		}
		return vStr(sb.String())
	})
	b["str"] = fixed(ts("str|int|bool"), func(_ *Interp, a []Value) Value {
		switch a[0].K {
		case KInt:
			return vStr(strconv.FormatInt(a[0].I, 10))
		case KBool:
			return vStr(boolText(a[0]))
		}
		return a[0]
	})
	b["int"] = fixed(ts("str|int"), func(_ *Interp, a []Value) Value {
		if a[0].K == KInt {
			return a[0]
		}
		s := a[0].S
		digits := s
		if strings.HasPrefix(s, "-") {
			digits = s[1:]
		}
		if digits == "" || strings.Trim(digits, "0123456789") != "" {
			raise(kilnerr.Arg, "fn int: bad integer")
		}
		n, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			raise(kilnerr.Arg, "fn int: bad integer")
		}
		return vInt(n)
	})
	b["dirname"] = fixed(ts("str"), func(_ *Interp, a []Value) Value {
		if i := strings.LastIndexByte(a[0].S, '/'); i >= 0 {
			return vStr(a[0].S[:i])
		}
		return vStr("")
	})
	b["basename"] = fixed(ts("str"), func(_ *Interp, a []Value) Value { return vStr(baseName(a[0].S)) })
	b["stem"] = fixed(ts("str"), func(_ *Interp, a []Value) Value {
		base := baseName(a[0].S)
		if i := extIndex(base); i >= 0 {
			return vStr(base[:i])
		}
		return vStr(base)
	})
	b["ext"] = fixed(ts("str"), func(_ *Interp, a []Value) Value {
		base := baseName(a[0].S)
		if i := extIndex(base); i >= 0 {
			return vStr(base[i:])
		}
		return vStr("")
	})
	b["pathjoin"] = &builtin{minArgs: 1, maxArgs: 8, types: ts("str"), fn: func(_ *Interp, a []Value) Value {
		parts := make([]string, 0, len(a))
		for _, v := range a {
			if v.S != "" {
				parts = append(parts, v.S)
			}
		}
		return vStr(strings.Join(parts, "/"))
	}}
	b["map"] = fixed(ts("list", "str"), func(_ *Interp, a []Value) Value {
		pat := a[1].S
		out := make([]Value, len(a[0].L))
		for i, e := range a[0].L {
			if e.K != KStr {
				typeErr("fn map element "+itoa(i), "str", e.K)
			}
			out[i] = vStr(applyMap(pat, e.S))
		}
		return vList(out)
	})
	b["filter"] = fixed(ts("list", "str"), func(_ *Interp, a []Value) Value { return filterList("filter", a, true) })
	b["reject"] = fixed(ts("list", "str"), func(_ *Interp, a []Value) Value { return filterList("reject", a, false) })
	b["sort"] = fixed(ts("list"), func(_ *Interp, a []Value) Value {
		out := append([]Value(nil), a[0].L...)
		sort.SliceStable(out, func(i, j int) bool { return Compare(out[i], out[j]) < 0 })
		return vList(out)
	})
	b["uniq"] = fixed(ts("list"), func(_ *Interp, a []Value) Value {
		seen := make(map[string]struct{}, len(a[0].L))
		out := make([]Value, 0, len(a[0].L))
		var key []byte
		for _, e := range a[0].L {
			key = appendKey(key[:0], e)
			if _, dup := seen[string(key)]; dup {
				continue
			}
			seen[string(key)] = struct{}{}
			out = append(out, e)
		}
		return vList(out)
	})
	b["reverse"] = fixed(ts("list"), func(_ *Interp, a []Value) Value {
		n := len(a[0].L)
		out := make([]Value, n)
		for i, e := range a[0].L {
			out[n-1-i] = e
		}
		return vList(out)
	})
	b["first"] = fixed(ts("list"), func(_ *Interp, a []Value) Value {
		if len(a[0].L) == 0 {
			raise(kilnerr.Arg, "fn first: empty list")
		}
		return a[0].L[0]
	})
	b["last"] = fixed(ts("list"), func(_ *Interp, a []Value) Value {
		if len(a[0].L) == 0 {
			raise(kilnerr.Arg, "fn last: empty list")
		}
		return a[0].L[len(a[0].L)-1]
	})
	b["slice"] = fixed(ts("list", "int", "int"), func(_ *Interp, a []Value) Value {
		s, n := clamp(a[1].I, a[2].I, len(a[0].L))
		return vList(append([]Value(nil), a[0].L[s:s+n]...))
	})
	b["has"] = fixed(ts("list", ""), func(_ *Interp, a []Value) Value {
		return vBool(indexOf(a[0].L, a[1]) >= 0)
	})
	b["indexof"] = fixed(ts("list", ""), func(_ *Interp, a []Value) Value {
		return vInt(int64(indexOf(a[0].L, a[1])))
	})
	b["range"] = fixed(ts("int"), func(_ *Interp, a []Value) Value {
		if a[0].I < 0 {
			raise(kilnerr.Arg, "fn range: negative")
		}
		out := make([]Value, a[0].I)
		for i := range out {
			out[i] = vInt(int64(i))
		}
		return vList(out)
	})
	b["sum"] = fixed(ts("list"), func(_ *Interp, a []Value) Value {
		var s int64
		for i, e := range a[0].L {
			if e.K != KInt {
				typeErr("fn sum element "+itoa(i), "int", e.K)
			}
			s += e.I
		}
		return vInt(s)
	})
	b["flatten"] = fixed(ts("list"), func(_ *Interp, a []Value) Value {
		var out []Value
		for _, e := range a[0].L {
			if e.K == KList {
				out = append(out, e.L...)
			} else {
				out = append(out, e)
			}
		}
		return vList(out)
	})
	b["zip"] = fixed(ts("list", "list"), func(_ *Interp, a []Value) Value {
		n := len(a[0].L)
		if len(a[1].L) < n {
			n = len(a[1].L)
		}
		out := make([]Value, n)
		for i := 0; i < n; i++ {
			out[i] = vList([]Value{a[0].L[i], a[1].L[i]})
		}
		return vList(out)
	})
	b["is_str"] = fixed(ts(""), func(_ *Interp, a []Value) Value { return vBool(a[0].K == KStr) })
	b["is_int"] = fixed(ts(""), func(_ *Interp, a []Value) Value { return vBool(a[0].K == KInt) })
	b["is_bool"] = fixed(ts(""), func(_ *Interp, a []Value) Value { return vBool(a[0].K == KBool) })
	b["is_list"] = fixed(ts(""), func(_ *Interp, a []Value) Value { return vBool(a[0].K == KList) })
	b["glob"] = fixed(ts("str"), func(ip *Interp, a []Value) Value {
		p, ok := glob.Compile(a[0].S)
		if !ok {
			raise(kilnerr.Arg, "fn glob: bad pattern")
		}
		cands := ip.fs.Candidates(p.LiteralPrefix())
		out := make([]Value, 0, 8)
		for _, c := range cands {
			if p.Match(c) {
				out = append(out, vStr(c))
			}
		}
		return vList(out)
	})
	builtins = b
}

func asciiMap(b []byte, lo, hi byte, delta int) []byte {
	for i, c := range b {
		if c >= lo && c <= hi {
			b[i] = byte(int(c) + delta)
		}
	}
	return b
}

// clamp implements the start/count clamping shared by substr and slice.
func clamp(start, count int64, n int) (int, int) {
	st := start
	if st < 0 {
		st += int64(n)
	}
	if st < 0 {
		st = 0
	}
	if st > int64(n) {
		st = int64(n)
	}
	c := count
	if c < 0 {
		c = 0
	}
	if c > int64(n)-st {
		c = int64(n) - st
	}
	return int(st), int(c)
}

func baseName(p string) string {
	if i := strings.LastIndexByte(p, '/'); i >= 0 {
		return p[i+1:]
	}
	return p
}

// extIndex returns the index of the last '.' in base that is not at index 0,
// or -1.
func extIndex(base string) int {
	i := strings.LastIndexByte(base, '.')
	if i <= 0 {
		return -1
	}
	return i
}

func applyMap(pat, elem string) string {
	if strings.IndexByte(pat, '%') < 0 {
		return pat
	}
	var sb strings.Builder
	for i := 0; i < len(pat); i++ {
		if pat[i] != '%' {
			sb.WriteByte(pat[i])
			continue
		}
		if i+1 < len(pat) && pat[i+1] == '%' {
			sb.WriteByte('%')
			i++
			continue
		}
		sb.WriteString(elem)
	}
	return sb.String()
}

func filterList(name string, a []Value, keep bool) Value {
	p, ok := glob.Compile(a[1].S)
	if !ok {
		raise(kilnerr.Arg, "fn "+name+": bad pattern")
	}
	out := make([]Value, 0, len(a[0].L))
	for i, e := range a[0].L {
		if e.K != KStr {
			typeErr("fn "+name+" element "+itoa(i), "str", e.K)
		}
		if p.Match(e.S) == keep {
			out = append(out, e)
		}
	}
	return vList(out)
}

func indexOf(l []Value, v Value) int {
	for i, e := range l {
		if Equal(e, v) {
			return i
		}
	}
	return -1
}

// BuiltinNames returns the names of all built-in functions, sorted.
func BuiltinNames() []string {
	names := make([]string, 0, len(builtins))
	for n := range builtins {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}
