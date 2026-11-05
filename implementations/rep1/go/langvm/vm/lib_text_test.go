package vm

import "testing"

func TestChars(t *testing.T) {
	wantStr(t, call("showBool", Bool(true)), "true")
	wantStr(t, call("showBool", Bool(false)), "false")
	wantInt(t, call("ord", Char('é')), 233)
	wantInt(t, call("ord", Char(0x10FFFF)), 0x10FFFF)
	for _, n := range []int64{0, 65, 0xD7FF, 0xE000, 0x10FFFF} {
		wantInt(t, Int(int64(call("chr", Int(n)).C())), n)
	}
	for _, n := range []int64{-1, 0xD800, 0xDBFF, 0xDFFF, 0x110000, 1 << 40, -1 << 40} {
		wantPanic(t, "invalid char code", "chr", Int(n))
	}
	type pred struct {
		name string
		f    func(r rune) bool
	}
	preds := []pred{
		{"isDigit", func(r rune) bool { return r >= '0' && r <= '9' }},
		{"isAlpha", func(r rune) bool { return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' }},
		{"isAlnum", func(r rune) bool { return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' }},
		{"isSpace", func(r rune) bool { return r == 9 || r == 10 || r == 11 || r == 12 || r == 13 || r == 32 }},
		{"isUpper", func(r rune) bool { return r >= 'A' && r <= 'Z' }},
		{"isLower", func(r rune) bool { return r >= 'a' && r <= 'z' }},
	}
	for r := rune(0); r < 300; r++ {
		for _, p := range preds {
			if got := call(p.name, Char(r)).B(); got != p.f(r) {
				t.Errorf("%s(%d) = %v", p.name, r, got)
			}
		}
		up, lo := r, r
		if r >= 'a' && r <= 'z' {
			up = r - 32
		}
		if r >= 'A' && r <= 'Z' {
			lo = r + 32
		}
		if call("toUpperC", Char(r)).C() != up || call("toLowerC", Char(r)).C() != lo {
			t.Errorf("case conversion of %d", r)
		}
	}
	// non-ASCII stays put
	if call("toUpperC", Char('é')).C() != 'é' || call("isAlpha", Char('é')).B() {
		t.Error("non-ASCII")
	}
	wantInt(t, call("cmpC", Char('a'), Char('b')), -1)
	wantInt(t, call("cmpC", Char('b'), Char('b')), 0)
	wantInt(t, call("cmpC", Char('c'), Char('b')), 1)
	wantStr(t, call("showChar", Char('x')), "x")
	wantStr(t, call("showChar", Char('é')), "é")
	wantStr(t, call("showChar", Char(0x1F600)), "\U0001F600")
	wantStr(t, call("showChar", Char(0)), "\x00")
}

func TestQuote(t *testing.T) {
	wantStr(t, call("quoteStr", GoStr("a\"b\n")), `"a\"b\n"`)
	wantStr(t, call("quoteStr", GoStr("tab\there\n")), `"tab\there\n"`)
	wantStr(t, call("quoteStr", GoStr("")), `""`)
	wantStr(t, call("quoteStr", GoStr("it's")), `"it's"`)
	wantStr(t, call("quoteStr", GoStr("a\\b\r")), `"a\\b\r"`)
	wantStr(t, call("quoteStr", GoStr("\x00\x01\x1f\x7f\u0080é")), `"\u{0}\u{1}\u{1f}\u{7f}`+"\u0080é"+`"`)
	wantStr(t, call("quoteChar", Char('\'')), `'\''`)
	wantStr(t, call("quoteChar", Char('"')), `'"'`)
	wantStr(t, call("quoteChar", Char('\u0001')), `'\u{1}'`)
	wantStr(t, call("quoteChar", Char('\\')), `'\\'`)
	wantStr(t, call("quoteChar", Char('\n')), `'\n'`)
	wantStr(t, call("quoteChar", Char(0x7f)), `'\u{7f}'`)
	wantStr(t, call("quoteChar", Char('a')), `'a'`)
	wantStr(t, call("quoteChar", Char('é')), `'é'`)
}

func TestStrBasics(t *testing.T) {
	s := GoStr("héllo, wörld")
	wantInt(t, call("strLen", s), 12)
	wantInt(t, call("strLen", GoStr("")), 0)
	if call("charAt", s, Int(1)).C() != 'é' || call("charAt", s, Int(8)).C() != 'ö' {
		t.Error("charAt")
	}
	wantPanic(t, "index out of bounds", "charAt", s, Int(12))
	wantPanic(t, "index out of bounds", "charAt", s, Int(-1))
	wantPanic(t, "index out of bounds", "charAt", GoStr(""), Int(0))
	wantStr(t, call("substr", s, Int(7), Int(12)), "wörld")
	wantStr(t, call("substr", s, Int(0), Int(0)), "")
	wantStr(t, call("substr", s, Int(12), Int(12)), "")
	wantStr(t, call("substr", s, Int(0), Int(12)), "héllo, wörld")
	wantPanic(t, "index out of bounds", "substr", s, Int(-1), Int(3))
	wantPanic(t, "index out of bounds", "substr", s, Int(3), Int(2))
	wantPanic(t, "index out of bounds", "substr", s, Int(3), Int(13))
	wantStr(t, call("upper", s), "HéLLO, WöRLD")
	wantStr(t, call("lower", GoStr("ABC É")), "abc É")
	wantStr(t, call("strCat", GoStr("ab"), GoStr("cd")), "abcd")
	wantStr(t, call("strCat", GoStr(""), GoStr("cd")), "cd")
	wantStr(t, call("strCat", GoStr("ab"), GoStr("")), "ab")
	wantStr(t, call("strRepeat", GoStr("ab"), Int(3)), "ababab")
	wantStr(t, call("strRepeat", GoStr("ab"), Int(0)), "")
	wantStr(t, call("strRepeat", GoStr(""), Int(5)), "")
	wantPanic(t, "negative count", "strRepeat", GoStr("ab"), Int(-1))
	wantPanic(t, "negative count", "strRepeat", GoStr(""), Int(-1))
	wantStr(t, call("strReverse", GoStr("abc")), "cba")
	wantStr(t, call("strReverse", GoStr("héy")), "yéh")
	wantStr(t, call("strReverse", GoStr("")), "")
	wantInt(t, call("strCmp", GoStr("abc"), GoStr("abd")), -1)
	wantInt(t, call("strCmp", GoStr("ab"), GoStr("ab")), 0)
	wantInt(t, call("strCmp", GoStr("b"), GoStr("ab")), 1)
	wantInt(t, call("strCmp", GoStr("a"), GoStr("ab")), -1)
	wantInt(t, call("strCmp", GoStr(""), GoStr("")), 0)
	wantInt(t, call("strCmp", GoStr("é"), GoStr("z")), 1)
}

func TestStrSearch(t *testing.T) {
	s := GoStr("héllo, wörld")
	wantInt(t, call("strIndexOf", s, GoStr("l")), 2)
	wantInt(t, call("strLastIndexOf", s, GoStr("l")), 10)
	wantInt(t, call("strIndexOf", s, GoStr("z")), -1)
	wantInt(t, call("strLastIndexOf", s, GoStr("z")), -1)
	wantInt(t, call("strIndexOf", s, GoStr("")), 0)
	wantInt(t, call("strLastIndexOf", s, GoStr("")), 12)
	wantInt(t, call("strIndexOf", GoStr(""), GoStr("")), 0)
	wantInt(t, call("strLastIndexOf", GoStr(""), GoStr("")), 0)
	wantInt(t, call("strIndexOf", GoStr(""), GoStr("a")), -1)
	wantInt(t, call("strIndexOf", GoStr("aab"), GoStr("ab")), 1)
	wantInt(t, call("strIndexOf", GoStr("aaa"), GoStr("aaaa")), -1)
	wantInt(t, call("strLastIndexOf", GoStr("aaa"), GoStr("aa")), 1)
	wantInt(t, call("strLastIndexOf", GoStr("abab"), GoStr("ab")), 2)
	wantInt(t, call("strLastIndexOf", GoStr("a"), GoStr("ab")), -1)
	wantBool(t, call("strContains", s, GoStr("wör")), true)
	wantBool(t, call("strContains", s, GoStr("wor")), false)
	wantBool(t, call("strContains", s, GoStr("")), true)
	wantBool(t, call("startsWith", s, GoStr("hé")), true)
	wantBool(t, call("startsWith", s, GoStr("")), true)
	wantBool(t, call("startsWith", GoStr("a"), GoStr("ab")), false)
	wantBool(t, call("startsWith", s, GoStr("é")), false)
	wantBool(t, call("endsWith", s, GoStr("örld")), true)
	wantBool(t, call("endsWith", s, GoStr("")), true)
	wantBool(t, call("endsWith", GoStr("b"), GoStr("ab")), false)
	wantBool(t, call("endsWith", s, GoStr("örl")), false)
}

func TestSplitJoinReplace(t *testing.T) {
	sp := func(s, sep string) []string { return listStrs(call("strSplit", GoStr(s), GoStr(sep))) }
	check := func(got, want []string) {
		t.Helper()
		if !eqStrs(got, want) {
			t.Errorf("got %q want %q", got, want)
		}
	}
	check(sp("a,,b", ","), []string{"a", "", "b"})
	check(sp("", ","), []string{""})
	check(sp(",a,", ","), []string{"", "a", ""})
	check(sp("aaa", "aa"), []string{"", "a"})
	check(sp("a,,b,", ","), []string{"a", "", "b", ""})
	check(sp("abc", ","), []string{"abc"})
	check(sp("a→b→c", "→"), []string{"a", "b", "c"})
	check(sp(",", ","), []string{"", ""})
	check(sp("abab", "ab"), []string{"", "", ""})
	wantPanic(t, "empty separator", "strSplit", GoStr("a"), GoStr(""))
	wantPanic(t, "empty separator", "strSplit", GoStr(""), GoStr(""))

	wantStr(t, call("strJoin", strList("a", "", "b", ""), GoStr("|")), "a||b|")
	wantStr(t, call("strJoin", strList(), GoStr("|")), "")
	wantStr(t, call("strJoin", strList("x"), GoStr("|")), "x")
	wantStr(t, call("strJoin", strList("x", "y"), GoStr("")), "xy")

	rep := func(s, f, to string) string { return gs(call("strReplace", GoStr(s), GoStr(f), GoStr(to))) }
	for _, c := range [][4]string{
		{"aaa", "aa", "b", "ba"}, {"abc", "x", "y", "abc"}, {"", "a", "b", ""}, {"abcabc", "b", "", "acac"},
		{"aaa", "a", "aa", "aaaaaa"}, {"abab", "ab", "ba", "baba"}, {"hello", "l", "L", "heLLo"},
		{"abc", "abc", "", ""}, {"a", "abc", "x", "a"}, {"xé", "é", "e", "xe"},
	} {
		if got := rep(c[0], c[1], c[2]); got != c[3] {
			t.Errorf("replace(%q,%q,%q) = %q, want %q", c[0], c[1], c[2], got, c[3])
		}
	}
	wantPanic(t, "empty separator", "strReplace", GoStr("abc"), GoStr(""), GoStr("x"))
	wantPanic(t, "empty separator", "strReplace", GoStr(""), GoStr(""), GoStr("x"))
}

func TestTrimPadChars(t *testing.T) {
	ws := " \t\n\v\f\r"
	wantStr(t, call("trim", GoStr(ws+"pad"+ws)), "pad")
	wantStr(t, call("trim", GoStr("  pad  ")), "pad")
	wantStr(t, call("trim", GoStr(ws)), "")
	wantStr(t, call("trim", GoStr("")), "")
	wantStr(t, call("trim", GoStr("a b")), "a b")
	wantStr(t, call("trim", GoStr(" x ")), " x ")
	wantStr(t, call("trimLeft", GoStr("  pad  ")), "pad  ")
	wantStr(t, call("trimRight", GoStr("  pad  ")), "  pad")
	wantStr(t, call("trimLeft", GoStr("   ")), "")
	wantStr(t, call("trimRight", GoStr("   ")), "")

	wantStr(t, call("padLeft", GoStr("7"), Int(3), Char('0')), "007")
	wantStr(t, call("padRight", GoStr("x"), Int(3), Char('-')), "x--")
	wantStr(t, call("padLeft", GoStr("abcd"), Int(3), Char('0')), "abcd")
	wantStr(t, call("padRight", GoStr("abcd"), Int(4), Char('0')), "abcd")
	wantStr(t, call("padLeft", GoStr(""), Int(2), Char('é')), "éé")
	wantStr(t, call("padRight", GoStr(""), Int(0), Char('é')), "")
	wantPanic(t, "negative count", "padLeft", GoStr("abcd"), Int(-1), Char('0'))
	wantPanic(t, "negative count", "padRight", GoStr(""), Int(-1), Char('0'))

	cs := call("chars", GoStr("héy"))
	if len(cs.P.V) != 3 || cs.P.V[1].C() != 'é' || cs.P.V[1].P.Kind != KChar {
		t.Error("chars")
	}
	if len(call("chars", GoStr("")).P.V) != 0 {
		t.Error("chars empty")
	}
	wantStr(t, call("strOfChars", cs), "héy")
	wantStr(t, call("strOfChars", List(nil)), "")
	wantStr(t, call("strOfChars", List([]Value{call("chr", Int(86)), Char('e'), Char('l')})), "Vel")
}

func TestStringImmutability(t *testing.T) {
	// Results must not alias in a way that appending corrupts the source.
	src := GoStr("hello world")
	sub := call("substr", src, Int(0), Int(5))
	_ = append(sub.P.S, 'X')
	wantStr(t, src, "hello world")
	tr := call("trim", GoStr(" ab "))
	_ = append(tr.P.S, 'X')
	parts := call("strSplit", src, GoStr(" "))
	_ = append(parts.P.V[0].P.S, 'X')
	wantStr(t, src, "hello world")
	// shared-string inputs are not modified
	u := call("upper", src)
	wantStr(t, src, "hello world")
	wantStr(t, u, "HELLO WORLD")
}

func TestFmt(t *testing.T) {
	f := func(tpl string, args ...string) Value { return call("fmt", GoStr(tpl), strList(args...)) }
	wantStr(t, f("{} + {} = {}", "1", "2", "3"), "1 + 2 = 3")
	wantStr(t, f("{{{}}}", "x"), "{x}")
	wantStr(t, f("100%"), "100%")
	wantStr(t, f(""), "")
	wantStr(t, f("{{}}"), "{}")
	wantStr(t, f("}}{{"), "}{")
	wantStr(t, f("[{}] [{}]", "007", "x--"), "[007] [x--]")
	wantStr(t, f("{}{}", "é", ""), "é")
	wantStr(t, f("{}", "{}"), "{}")
	bad := [][]string{
		{"{"}, {"}"}, {"{x}"}, {"{ }"}, {"a{"}, {"a}"}, {"{}"}, {"{}{}", "1"}, {"x", "1"}, {"{} {}", "1", "2", "3"},
		{"}{", "a"}, {"{}}", "1"}, {"{{}", "1"}, {"{} {", "1"}, {"{} }", "1"}, {"{} {x}", "1", "2", "3"},
	}
	for _, b := range bad {
		wantPanic(t, "bad format", "fmt", GoStr(b[0]), strList(b[1:]...))
	}
}

// SPEC 17 example 10.
func TestExample10(t *testing.T) {
	s := GoStr("héllo, wörld")
	wantInt(t, call("strLen", s), 12)
	wantStr(t, call("strCat", call("showChar", call("charAt", s, Int(1))), call("showChar", call("charAt", s, Int(8)))), "éö")
	wantStr(t, call("strJoin", call("strSplit", GoStr("a,,b,"), GoStr(",")), GoStr("|")), "a||b|")
	wantStr(t, call("fmt", GoStr("[{}] [{}]"), List([]Value{
		call("padLeft", GoStr("7"), Int(3), Char('0')), call("padRight", GoStr("x"), Int(3), Char('-'))})), "[007] [x--]")
	wantStr(t, call("quoteStr", GoStr("tab\there\n")), `"tab\there\n"`)
	wantBool(t, call("isSpace", Char('\t')), true)
	wantStr(t, call("quoteChar", Char('\'')), `'\''`)
}
