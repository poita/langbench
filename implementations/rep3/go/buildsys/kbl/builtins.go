package kbl

import (
	"sort"
	"strconv"
	"strings"

	"buildsys/diag"
	"buildsys/glob"
)

// typeSpec is a set of accepted value kinds with its error-message token.
type typeSpec struct {
	name string
	mask uint8
}

func (t typeSpec) accepts(k Kind) bool { return t.mask&(1<<k) != 0 }

var (
	tAny        = typeSpec{"any", 0xf}
	tStr        = typeSpec{"str", 1 << KindStr}
	tInt        = typeSpec{"int", 1 << KindInt}
	tBool       = typeSpec{"bool", 1 << KindBool}
	tList       = typeSpec{"list", 1 << KindList}
	tStrList    = typeSpec{"str|list", 1<<KindStr | 1<<KindList}
	tStrInt     = typeSpec{"str|int", 1<<KindStr | 1<<KindInt}
	tStrIntBool = typeSpec{"str|int|bool", 1<<KindStr | 1<<KindInt | 1<<KindBool}
)

// builtin describes one built-in function. For variadic functions the last
// entry of types applies to all further arguments.
type builtin struct {
	name     string
	min, max int
	types    []typeSpec
	fn       func(in *interp, a []Value) Value
}

var builtins map[string]*builtin

func init() {
	defs := []*builtin{
		{"len", 1, 1, []typeSpec{tStrList}, fnLen},
		{"count", 1, 1, []typeSpec{tList}, func(_ *interp, a []Value) Value { return intVal(int64(len(a[0].L))) }},
		{"upper", 1, 1, []typeSpec{tStr}, fnUpper},
		{"lower", 1, 1, []typeSpec{tStr}, fnLower},
		{"trim", 1, 1, []typeSpec{tStr}, func(_ *interp, a []Value) Value { return strVal(strings.Trim(a[0].S, " \t\n\r")) }},
		{"replace", 3, 3, []typeSpec{tStr, tStr, tStr}, fnReplace},
		{"starts_with", 2, 2, []typeSpec{tStr, tStr}, func(_ *interp, a []Value) Value { return boolVal(strings.HasPrefix(a[0].S, a[1].S)) }},
		{"ends_with", 2, 2, []typeSpec{tStr, tStr}, func(_ *interp, a []Value) Value { return boolVal(strings.HasSuffix(a[0].S, a[1].S)) }},
		{"contains", 2, 2, []typeSpec{tStr, tStr}, func(_ *interp, a []Value) Value { return boolVal(strings.Contains(a[0].S, a[1].S)) }},
		{"substr", 3, 3, []typeSpec{tStr, tInt, tInt}, fnSubstr},
		{"split", 2, 2, []typeSpec{tStr, tStr}, fnSplit},
		{"join", 2, 2, []typeSpec{tList, tStr}, fnJoin},
		{"str", 1, 1, []typeSpec{tStrIntBool}, fnStr},
		{"int", 1, 1, []typeSpec{tStrInt}, fnInt},
		{"dirname", 1, 1, []typeSpec{tStr}, fnDirname},
		{"basename", 1, 1, []typeSpec{tStr}, func(_ *interp, a []Value) Value { return strVal(baseName(a[0].S)) }},
		{"stem", 1, 1, []typeSpec{tStr}, fnStem},
		{"ext", 1, 1, []typeSpec{tStr}, fnExt},
		{"pathjoin", 1, 8, []typeSpec{tStr}, fnPathjoin},
		{"map", 2, 2, []typeSpec{tList, tStr}, fnMap},
		{"filter", 2, 2, []typeSpec{tList, tStr}, func(_ *interp, a []Value) Value { return fnFilter("filter", a, true) }},
		{"reject", 2, 2, []typeSpec{tList, tStr}, func(_ *interp, a []Value) Value { return fnFilter("reject", a, false) }},
		{"sort", 1, 1, []typeSpec{tList}, fnSort},
		{"uniq", 1, 1, []typeSpec{tList}, fnUniq},
		{"reverse", 1, 1, []typeSpec{tList}, fnReverse},
		{"first", 1, 1, []typeSpec{tList}, func(_ *interp, a []Value) Value { return endElem("first", a[0].L, 0) }},
		{"last", 1, 1, []typeSpec{tList}, func(_ *interp, a []Value) Value { return endElem("last", a[0].L, len(a[0].L)-1) }},
		{"slice", 3, 3, []typeSpec{tList, tInt, tInt}, fnSlice},
		{"has", 2, 2, []typeSpec{tList, tAny}, fnHas},
		{"indexof", 2, 2, []typeSpec{tList, tAny}, fnIndexof},
		{"range", 1, 1, []typeSpec{tInt}, fnRange},
		{"sum", 1, 1, []typeSpec{tList}, fnSum},
		{"flatten", 1, 1, []typeSpec{tList}, fnFlatten},
		{"zip", 2, 2, []typeSpec{tList, tList}, fnZip},
		{"is_str", 1, 1, []typeSpec{tAny}, func(_ *interp, a []Value) Value { return boolVal(a[0].Kind == KindStr) }},
		{"is_int", 1, 1, []typeSpec{tAny}, func(_ *interp, a []Value) Value { return boolVal(a[0].Kind == KindInt) }},
		{"is_bool", 1, 1, []typeSpec{tAny}, func(_ *interp, a []Value) Value { return boolVal(a[0].Kind == KindBool) }},
		{"is_list", 1, 1, []typeSpec{tAny}, func(_ *interp, a []Value) Value { return boolVal(a[0].Kind == KindList) }},
		{"glob", 1, 1, []typeSpec{tStr}, fnGlob},
	}
	builtins = make(map[string]*builtin, len(defs))
	for _, d := range defs {
		builtins[d.name] = d
	}
}

// BuiltinNames returns the sorted names of all built-in functions.
func BuiltinNames() []string {
	names := make([]string, 0, len(builtins))
	for n := range builtins {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

func typeErr(site string, want string, got Kind) *diag.Error {
	return diag.New(diag.Type, "%s: expected %s, got %s", site, want, got)
}

// call performs a built-in call after its arguments have been evaluated:
// arity, then argument types in ascending order, then the function itself.
func (b *builtin) call(in *interp, args []Value) Value {
	if len(args) < b.min || len(args) > b.max {
		if b.min == b.max {
			panic(diag.New(diag.Arity, "fn %s: expected %d, got %d", b.name, b.min, len(args)))
		}
		panic(diag.New(diag.Arity, "fn %s: expected %d-%d, got %d", b.name, b.min, b.max, len(args)))
	}
	for i, a := range args {
		t := b.types[len(b.types)-1]
		if i < len(b.types) {
			t = b.types[i]
		}
		if !t.accepts(a.Kind) {
			panic(typeErr("fn "+b.name+" argument "+strconv.Itoa(i+1), t.name, a.Kind))
		}
	}
	return b.fn(in, args)
}

func argErr(fn, reason string) *diag.Error { return diag.New(diag.Arg, "fn %s: %s", fn, reason) }

func fnLen(_ *interp, a []Value) Value {
	if a[0].Kind == KindStr {
		return intVal(int64(len(a[0].S)))
	}
	return intVal(int64(len(a[0].L)))
}

func fnUpper(_ *interp, a []Value) Value {
	b := []byte(a[0].S)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return strVal(string(b))
}

func fnLower(_ *interp, a []Value) Value {
	b := []byte(a[0].S)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return strVal(string(b))
}

func fnReplace(_ *interp, a []Value) Value {
	if a[1].S == "" {
		panic(argErr("replace", "empty pattern"))
	}
	return strVal(strings.ReplaceAll(a[0].S, a[1].S, a[2].S))
}

// clamp applies the shared substr/slice rules and returns the half-open range.
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
	return int(s), int(s + c)
}

func fnSubstr(_ *interp, a []Value) Value {
	lo, hi := clamp(len(a[0].S), a[1].I, a[2].I)
	return strVal(a[0].S[lo:hi])
}

func fnSlice(_ *interp, a []Value) Value {
	lo, hi := clamp(len(a[0].L), a[1].I, a[2].I)
	return listVal(append([]Value(nil), a[0].L[lo:hi]...))
}

func fnSplit(_ *interp, a []Value) Value {
	if a[1].S == "" {
		panic(argErr("split", "empty separator"))
	}
	parts := strings.Split(a[0].S, a[1].S)
	out := make([]Value, len(parts))
	for i, p := range parts {
		out[i] = strVal(p)
	}
	return listVal(out)
}

func fnJoin(_ *interp, a []Value) Value {
	var b strings.Builder
	for i, e := range a[0].L {
		if i > 0 {
			b.WriteString(a[1].S)
		}
		switch e.Kind {
		case KindStr:
			b.WriteString(e.S)
		case KindInt:
			b.WriteString(strconv.FormatInt(e.I, 10))
		default:
			panic(typeErr("fn join element "+strconv.Itoa(i), "str|int", e.Kind))
		}
	}
	return strVal(b.String())
}

func fnStr(_ *interp, a []Value) Value {
	s, _ := a[0].Text()
	return strVal(s)
}

func fnInt(_ *interp, a []Value) Value {
	if a[0].Kind == KindInt {
		return a[0]
	}
	s := a[0].S
	digits := s
	if strings.HasPrefix(digits, "-") {
		digits = digits[1:]
	}
	if digits == "" {
		panic(argErr("int", "bad integer"))
	}
	for i := 0; i < len(digits); i++ {
		if !isDigit(digits[i]) {
			panic(argErr("int", "bad integer"))
		}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic(argErr("int", "bad integer"))
	}
	return intVal(n)
}

func baseName(s string) string { return s[strings.LastIndexByte(s, '/')+1:] }

func fnDirname(_ *interp, a []Value) Value {
	i := strings.LastIndexByte(a[0].S, '/')
	if i < 0 {
		return strVal("")
	}
	return strVal(a[0].S[:i])
}

// splitExt splits a basename at its last '.' that is not at index 0.
func splitExt(p string) (stem, ext string) {
	b := baseName(p)
	if i := strings.LastIndexByte(b, '.'); i > 0 {
		return b[:i], b[i:]
	}
	return b, ""
}

func fnStem(_ *interp, a []Value) Value { s, _ := splitExt(a[0].S); return strVal(s) }
func fnExt(_ *interp, a []Value) Value  { _, e := splitExt(a[0].S); return strVal(e) }

func fnPathjoin(_ *interp, a []Value) Value {
	parts := make([]string, 0, len(a))
	for _, v := range a {
		if v.S != "" {
			parts = append(parts, v.S)
		}
	}
	return strVal(strings.Join(parts, "/"))
}

func strElems(fn string, l []Value) {
	for i, e := range l {
		if e.Kind != KindStr {
			panic(typeErr("fn "+fn+" element "+strconv.Itoa(i), "str", e.Kind))
		}
	}
}

func fnMap(_ *interp, a []Value) Value {
	strElems("map", a[0].L)
	pat := a[1].S
	out := make([]Value, len(a[0].L))
	for i, e := range a[0].L {
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
		out[i] = strVal(b.String())
	}
	return listVal(out)
}

func fnFilter(name string, a []Value, keep bool) Value {
	p, err := glob.Compile(a[1].S)
	if err != nil {
		panic(argErr(name, "bad pattern"))
	}
	var out []Value
	for i, e := range a[0].L {
		if e.Kind != KindStr {
			panic(typeErr("fn "+name+" element "+strconv.Itoa(i), "str", e.Kind))
		}
		if p.Match(e.S) == keep {
			out = append(out, e)
		}
	}
	return listVal(out)
}

func fnSort(_ *interp, a []Value) Value {
	out := append([]Value(nil), a[0].L...)
	sort.SliceStable(out, func(i, j int) bool { return Compare(out[i], out[j]) < 0 })
	return listVal(out)
}

func fnUniq(_ *interp, a []Value) Value {
	var out []Value
	seen := map[string]struct{}{}
	for _, e := range a[0].L {
		if e.Kind == KindList {
			dup := false
			for _, o := range out {
				if Equal(o, e) {
					dup = true
					break
				}
			}
			if dup {
				continue
			}
		} else {
			key := string(rune('0'+e.Kind)) + e.S + strconv.FormatInt(e.I, 10)
			if e.Kind == KindStr {
				key = "s" + e.S
			}
			if _, dup := seen[key]; dup {
				continue
			}
			seen[key] = struct{}{}
		}
		out = append(out, e)
	}
	return listVal(out)
}

func fnReverse(_ *interp, a []Value) Value {
	l := a[0].L
	out := make([]Value, len(l))
	for i, e := range l {
		out[len(l)-1-i] = e
	}
	return listVal(out)
}

func endElem(fn string, l []Value, i int) Value {
	if len(l) == 0 {
		panic(argErr(fn, "empty list"))
	}
	return l[i]
}

func fnHas(_ *interp, a []Value) Value {
	for _, e := range a[0].L {
		if Equal(e, a[1]) {
			return boolVal(true)
		}
	}
	return boolVal(false)
}

func fnIndexof(_ *interp, a []Value) Value {
	for i, e := range a[0].L {
		if Equal(e, a[1]) {
			return intVal(int64(i))
		}
	}
	return intVal(-1)
}

func fnRange(_ *interp, a []Value) Value {
	if a[0].I < 0 {
		panic(argErr("range", "negative"))
	}
	out := make([]Value, a[0].I)
	for i := range out {
		out[i] = intVal(int64(i))
	}
	return listVal(out)
}

func fnSum(_ *interp, a []Value) Value {
	var s int64
	for i, e := range a[0].L {
		if e.Kind != KindInt {
			panic(typeErr("fn sum element "+strconv.Itoa(i), "int", e.Kind))
		}
		s += e.I
	}
	return intVal(s)
}

func fnFlatten(_ *interp, a []Value) Value {
	var out []Value
	for _, e := range a[0].L {
		if e.Kind == KindList {
			out = append(out, e.L...)
		} else {
			out = append(out, e)
		}
	}
	return listVal(out)
}

func fnZip(_ *interp, a []Value) Value {
	n := len(a[0].L)
	if len(a[1].L) < n {
		n = len(a[1].L)
	}
	out := make([]Value, n)
	for i := range out {
		out[i] = listVal([]Value{a[0].L[i], a[1].L[i]})
	}
	return listVal(out)
}

func fnGlob(in *interp, a []Value) Value {
	p, err := glob.Compile(a[0].S)
	if err != nil {
		panic(argErr("glob", "bad pattern"))
	}
	var out []Value
	for _, path := range in.fs.Candidates(p.Prefix()) {
		if p.Match(path) {
			out = append(out, strVal(path))
		}
	}
	return listVal(out)
}
