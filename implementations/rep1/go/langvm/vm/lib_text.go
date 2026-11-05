package vm

// asciiStrs caches the one-character strings of ASCII scalars.
var asciiStrs [128]Value

func init() {
	for i := range asciiStrs {
		asciiStrs[i] = Str([]rune{rune(i)})
	}

	register("showBool", func(m *VM, a []Value) Value {
		if a[0].N != 0 {
			return strTrue
		}
		return strFalse
	})
	register("ord", func(m *VM, a []Value) Value { return Int(a[0].N) })
	register("chr", func(m *VM, a []Value) Value {
		n := a[0].N
		if n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF) {
			m.Panic("invalid char code")
		}
		return Char(rune(n))
	})
	register("isDigit", func(m *VM, a []Value) Value { c := a[0].N; return Bool(c >= '0' && c <= '9') })
	register("isAlpha", func(m *VM, a []Value) Value { return Bool(isAlphaC(a[0].N)) })
	register("isAlnum", func(m *VM, a []Value) Value {
		c := a[0].N
		return Bool(isAlphaC(c) || (c >= '0' && c <= '9'))
	})
	register("isSpace", func(m *VM, a []Value) Value { return Bool(isSpaceC(rune(a[0].N))) })
	register("isUpper", func(m *VM, a []Value) Value { c := a[0].N; return Bool(c >= 'A' && c <= 'Z') })
	register("isLower", func(m *VM, a []Value) Value { c := a[0].N; return Bool(c >= 'a' && c <= 'z') })
	register("toUpperC", func(m *VM, a []Value) Value { return Char(upperC(rune(a[0].N))) })
	register("toLowerC", func(m *VM, a []Value) Value { return Char(lowerC(rune(a[0].N))) })
	register("cmpC", func(m *VM, a []Value) Value { return Int(cmpInt(a[0].N, a[1].N)) })
	register("showChar", func(m *VM, a []Value) Value {
		c := a[0].N
		if c >= 0 && c < 128 {
			return asciiStrs[c]
		}
		return Str([]rune{rune(c)})
	})
	register("quoteChar", func(m *VM, a []Value) Value {
		out := make([]rune, 0, 8)
		out = append(out, '\'')
		out = appendEscaped(out, rune(a[0].N), '\'')
		out = append(out, '\'')
		return Str(out)
	})

	register("strLen", func(m *VM, a []Value) Value { return Int(int64(len(a[0].P.S))) })
	register("charAt", func(m *VM, a []Value) Value {
		s := a[0].P.S
		i := a[1].N
		if uint64(i) >= uint64(len(s)) {
			m.Panic("index out of bounds")
		}
		return Char(s[i])
	})
	register("substr", func(m *VM, a []Value) Value {
		s := a[0].P.S
		from, to := a[1].N, a[2].N
		if from < 0 || from > to || to > int64(len(s)) {
			m.Panic("index out of bounds")
		}
		if from == 0 && to == int64(len(s)) {
			return a[0]
		}
		return Str(s[from:to:to])
	})
	register("strCat", func(m *VM, a []Value) Value {
		x, y := a[0].P.S, a[1].P.S
		if len(x) == 0 {
			return a[1]
		}
		if len(y) == 0 {
			return a[0]
		}
		out := make([]rune, len(x)+len(y))
		copy(out, x)
		copy(out[len(x):], y)
		return Str(out)
	})
	register("strRepeat", func(m *VM, a []Value) Value {
		s := a[0].P.S
		n := a[1].N
		if n < 0 {
			m.Panic("negative count")
		}
		if n == 0 || len(s) == 0 {
			return Str(nil)
		}
		out := make([]rune, 0, len(s)*int(n))
		for i := int64(0); i < n; i++ {
			out = append(out, s...)
		}
		return Str(out)
	})
	register("strIndexOf", func(m *VM, a []Value) Value {
		return Int(int64(indexRunes(a[0].P.S, a[1].P.S, 0)))
	})
	register("strLastIndexOf", func(m *VM, a []Value) Value {
		s, sub := a[0].P.S, a[1].P.S
		for i := len(s) - len(sub); i >= 0; i-- {
			if hasPrefixAt(s, sub, i) {
				return Int(int64(i))
			}
		}
		return Int(-1)
	})
	register("strContains", func(m *VM, a []Value) Value {
		return Bool(indexRunes(a[0].P.S, a[1].P.S, 0) >= 0)
	})
	register("startsWith", func(m *VM, a []Value) Value {
		s, p := a[0].P.S, a[1].P.S
		return Bool(len(p) <= len(s) && hasPrefixAt(s, p, 0))
	})
	register("endsWith", func(m *VM, a []Value) Value {
		s, p := a[0].P.S, a[1].P.S
		return Bool(len(p) <= len(s) && hasPrefixAt(s, p, len(s)-len(p)))
	})
	register("strSplit", func(m *VM, a []Value) Value {
		s, sep := a[0].P.S, a[1].P.S
		if len(sep) == 0 {
			m.Panic("empty separator")
		}
		var parts []Value
		start := 0
		for {
			j := indexRunes(s, sep, start)
			if j < 0 {
				break
			}
			parts = append(parts, Str(s[start:j:j]))
			start = j + len(sep)
		}
		parts = append(parts, Str(s[start:len(s):len(s)]))
		return List(parts)
	})
	register("strJoin", func(m *VM, a []Value) Value {
		parts := a[0].P.V
		sep := a[1].P.S
		if len(parts) == 0 {
			return Str(nil)
		}
		total := len(sep) * (len(parts) - 1)
		for _, p := range parts {
			total += len(p.P.S)
		}
		out := make([]rune, 0, total)
		for i, p := range parts {
			if i > 0 {
				out = append(out, sep...)
			}
			out = append(out, p.P.S...)
		}
		return Str(out)
	})
	register("strReplace", func(m *VM, a []Value) Value {
		s, from, to := a[0].P.S, a[1].P.S, a[2].P.S
		if len(from) == 0 {
			m.Panic("empty separator")
		}
		j := indexRunes(s, from, 0)
		if j < 0 {
			return a[0]
		}
		out := make([]rune, 0, len(s)+len(to))
		start := 0
		for j >= 0 {
			out = append(out, s[start:j]...)
			out = append(out, to...)
			start = j + len(from)
			j = indexRunes(s, from, start)
		}
		out = append(out, s[start:]...)
		return Str(out)
	})
	register("trim", func(m *VM, a []Value) Value {
		s := a[0].P.S
		i, j := 0, len(s)
		for i < j && isSpaceC(s[i]) {
			i++
		}
		for j > i && isSpaceC(s[j-1]) {
			j--
		}
		if i == 0 && j == len(s) {
			return a[0]
		}
		return Str(s[i:j:j])
	})
	register("trimLeft", func(m *VM, a []Value) Value {
		s := a[0].P.S
		i := 0
		for i < len(s) && isSpaceC(s[i]) {
			i++
		}
		if i == 0 {
			return a[0]
		}
		return Str(s[i:len(s):len(s)])
	})
	register("trimRight", func(m *VM, a []Value) Value {
		s := a[0].P.S
		j := len(s)
		for j > 0 && isSpaceC(s[j-1]) {
			j--
		}
		if j == len(s) {
			return a[0]
		}
		return Str(s[:j:j])
	})
	register("upper", func(m *VM, a []Value) Value {
		s := a[0].P.S
		out := make([]rune, len(s))
		for i, c := range s {
			out[i] = upperC(c)
		}
		return Str(out)
	})
	register("lower", func(m *VM, a []Value) Value {
		s := a[0].P.S
		out := make([]rune, len(s))
		for i, c := range s {
			out[i] = lowerC(c)
		}
		return Str(out)
	})
	register("strCmp", func(m *VM, a []Value) Value {
		return Int(int64(CompareStr(a[0].P.S, a[1].P.S)))
	})
	register("chars", func(m *VM, a []Value) Value {
		s := a[0].P.S
		out := make([]Value, len(s))
		for i, c := range s {
			out[i] = Char(c)
		}
		return List(out)
	})
	register("strOfChars", func(m *VM, a []Value) Value {
		cs := a[0].P.V
		out := make([]rune, len(cs))
		for i, c := range cs {
			out[i] = rune(c.N)
		}
		return Str(out)
	})
	register("strReverse", func(m *VM, a []Value) Value {
		s := a[0].P.S
		n := len(s)
		out := make([]rune, n)
		for i, c := range s {
			out[n-1-i] = c
		}
		return Str(out)
	})
	register("quoteStr", func(m *VM, a []Value) Value {
		s := a[0].P.S
		out := make([]rune, 0, len(s)+2)
		out = append(out, '"')
		for _, c := range s {
			out = appendEscaped(out, c, '"')
		}
		out = append(out, '"')
		return Str(out)
	})
	register("padLeft", func(m *VM, a []Value) Value { return padStr(m, a, true) })
	register("padRight", func(m *VM, a []Value) Value { return padStr(m, a, false) })
	register("fmt", libFmt)
}

var (
	strTrue  = GoStr("true")
	strFalse = GoStr("false")
)

func isAlphaC(c int64) bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

func isSpaceC(c rune) bool { return c == ' ' || (c >= 9 && c <= 13) }

func upperC(c rune) rune {
	if c >= 'a' && c <= 'z' {
		return c - 32
	}
	return c
}

func lowerC(c rune) rune {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

func hasPrefixAt(s, p []rune, at int) bool {
	if at < 0 || at+len(p) > len(s) {
		return false
	}
	for k, c := range p {
		if s[at+k] != c {
			return false
		}
	}
	return true
}

// indexRunes returns the smallest i >= from with sub occurring at i, or -1.
// An empty sub gives from (callers guarantee from <= len(s)).
func indexRunes(s, sub []rune, from int) int {
	if len(sub) == 0 {
		return from
	}
	first := sub[0]
	last := len(s) - len(sub)
	for i := from; i <= last; i++ {
		if s[i] != first {
			continue
		}
		k := 1
		for k < len(sub) && s[i+k] == sub[k] {
			k++
		}
		if k == len(sub) {
			return i
		}
	}
	return -1
}

// appendEscaped appends the escape of c (SPEC 15.5); quote is the delimiter
// that must be escaped (' or ").
func appendEscaped(out []rune, c rune, quote rune) []rune {
	switch {
	case c == '\\':
		return append(out, '\\', '\\')
	case c == quote:
		return append(out, '\\', quote)
	case c == '\n':
		return append(out, '\\', 'n')
	case c == '\r':
		return append(out, '\\', 'r')
	case c == '\t':
		return append(out, '\\', 't')
	case c < 0x20 || c == 0x7f:
		out = append(out, '\\', 'u', '{')
		var tmp [8]rune
		i := len(tmp)
		v := uint32(c)
		for v > 0 {
			i--
			tmp[i] = rune(digitChars[v&15])
			v >>= 4
		}
		if i == len(tmp) {
			i--
			tmp[i] = '0'
		}
		out = append(out, tmp[i:]...)
		return append(out, '}')
	}
	return append(out, c)
}

func padStr(m *VM, a []Value, left bool) Value {
	s := a[0].P.S
	w := a[1].N
	if w < 0 {
		m.Panic("negative count")
	}
	if int64(len(s)) >= w {
		return a[0]
	}
	n := int(w) - len(s)
	out := make([]rune, int(w))
	c := rune(a[2].N)
	if left {
		for i := 0; i < n; i++ {
			out[i] = c
		}
		copy(out[n:], s)
	} else {
		copy(out, s)
		for i := len(s); i < len(out); i++ {
			out[i] = c
		}
	}
	return Str(out)
}

// libFmt implements fmt (SPEC 15.9).
func libFmt(m *VM, a []Value) Value {
	t := a[0].P.S
	args := a[1].P.V
	out := make([]rune, 0, len(t)+16)
	used := 0
	for i := 0; i < len(t); i++ {
		c := t[i]
		switch c {
		case '{':
			if i+1 >= len(t) {
				m.Panic("bad format")
			}
			switch t[i+1] {
			case '{':
				out = append(out, '{')
			case '}':
				if used < len(args) {
					out = append(out, args[used].P.S...)
				}
				used++
			default:
				m.Panic("bad format")
			}
			i++
		case '}':
			if i+1 >= len(t) || t[i+1] != '}' {
				m.Panic("bad format")
			}
			out = append(out, '}')
			i++
		default:
			out = append(out, c)
		}
	}
	if used != len(args) {
		m.Panic("bad format")
	}
	return Str(out)
}
