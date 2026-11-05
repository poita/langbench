package toml

import "testing"

func decodeJSON(t *testing.T, doc string) string {
	t.Helper()
	root, err := Parse([]byte(doc))
	if err != nil {
		t.Fatalf("Parse(%q): %v", doc, err)
	}
	return string(root.AppendJSON(nil))
}

func TestParseValid(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", "", `{}`},
		{"string", `a = "x"`, `{"a":{"type":"string","value":"x"}}`},
		{"crlf", "a = 1\r\nb = 2\r\n", `{"a":{"type":"integer","value":"1"},"b":{"type":"integer","value":"2"}}`},
		{"dotted", "a.b = 1\na.c = 2", `{"a":{"b":{"type":"integer","value":"1"},"c":{"type":"integer","value":"2"}}}`},
		{"quoted key", `"a b" = true`, `{"a b":{"type":"bool","value":"true"}}`},
		{"same key forms", `"é" = 1`, `{"é":{"type":"integer","value":"1"}}`},
		{"header", "[a.b]\nx = 1", `{"a":{"b":{"x":{"type":"integer","value":"1"}}}}`},
		{"implicit then explicit", "[a.b]\n[a]\nx=1", `{"a":{"b":{},"x":{"type":"integer","value":"1"}}}`},
		{"aot", "[[a]]\nx=1\n[[a]]\nx=2\n[a.sub]\ny=3",
			`{"a":[{"x":{"type":"integer","value":"1"}},{"sub":{"y":{"type":"integer","value":"3"}},"x":{"type":"integer","value":"2"}}]}`},
		{"dotted then deeper header", "[fruit]\napple.color = \"red\"\n[fruit.apple.texture]\nx=1",
			`{"fruit":{"apple":{"color":{"type":"string","value":"red"},"texture":{"x":{"type":"integer","value":"1"}}}}}`},
		{"inline table", "a = { b = 1, c.d = 2 }", `{"a":{"b":{"type":"integer","value":"1"},"c":{"d":{"type":"integer","value":"2"}}}}`},
		{"array multiline", "a = [\n 1, # c\n 2,\n]", `{"a":[{"type":"integer","value":"1"},{"type":"integer","value":"2"}]}`},
		{"inline with multiline array", "a = { b = [\n1\n]}", `{"a":{"b":[{"type":"integer","value":"1"}]}}`},
		{"comment", "# hi\na = 1 # there\n", `{"a":{"type":"integer","value":"1"}}`},
		{"type value keys", "type = {a=1}\n[x]\ntype=\"a\"\nvalue=\"b\"", `{"type":{"a":{"type":"integer","value":"1"}},"x":{"type":{"type":"string","value":"a"},"value":{"type":"string","value":"b"}}}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := decodeJSON(t, tc.in); got != tc.want {
				t.Errorf("got  %s\nwant %s", got, tc.want)
			}
		})
	}
}

func TestParseInvalid(t *testing.T) {
	tests := []struct{ name, in string }{
		{"bom", "\xef\xbb\xbfa = 1"},
		{"bad utf8", "a = \"\xff\""},
		{"overlong", "a = \"\xc0\xaf\""},
		{"surrogate", "a = \"\xed\xa0\x80\""},
		{"lone cr", "a = 1\rb = 2"},
		{"cr in string", "a = \"x\ry\""},
		{"cr in comment", "# x\ry\n"},
		{"nul in comment", "# x\x00y\n"},
		{"del in string", "a = \"\x7f\""},
		{"no value", "a ="},
		{"no equals", "a"},
		{"garbage after value", "a = 1 b = 2"},
		{"duplicate key", "a = 1\na = 2"},
		{"duplicate via dotted", "a.b = 1\na = 2"},
		{"table twice", "[a]\n[a]"},
		{"table after dotted", "a.b = 1\n[a]"},
		{"header targets dotted", "[f]\na.b=1\n[f.a]"},
		{"dotted into header table", "[a.b]\n[a]\nb.c.t = 1"},
		{"extend inline", "a = {b=1}\n[a.c]"},
		{"dotted into inline", "a = {b=1}\na.c = 2"},
		{"inline dup", "a = {b=1, b=2}"},
		{"inline newline", "a = {b=1,\nc=2}"},
		{"inline trailing comma", "a = {b=1,}"},
		{"array leading comma", "a = [,1]"},
		{"array double comma", "a = [1,,2]"},
		{"aot over array", "a = [1]\n[[a]]"},
		{"aot over table", "[a]\n[[a]]"},
		{"table over aot", "[[a]]\n[a]"},
		{"through scalar", "a = 1\n[a.b]"},
		{"spaced brackets", "[ [a] ]"},
		{"spaced brackets 2", "[[a] ]"},
		{"bad escape", `a = "\q"`},
		{"surrogate escape", `a = "\ud800"`},
		{"big escape", `a = "\U00110000"`},
		{"short escape", `a = "\u12"`},
		{"newline in string", "a = \"x\ny\""},
		{"multiline six quotes", "a = \"\"\"x\"\"\"\"\"\"\n"},
		{"multi literal six quotes", "a = '''x''''''\n"},
		{"unterminated", `a = "x`},
		{"multi key", "\"\"\"a\"\"\" = 1"},
		{"leading zero", "a = 01"},
		{"signed zero prefix", "a = +01"},
		{"upper prefix", "a = 0X1"},
		{"signed hex", "a = -0x1"},
		{"underscore end", "a = 1_"},
		{"underscore double", "a = 1__0"},
		{"underscore start", "a = _1"},
		{"int overflow", "a = 9223372036854775808"},
		{"hex overflow", "a = 0xFFFFFFFFFFFFFFFF"},
		{"neg overflow", "a = -9223372036854775809"},
		{"float no int", "a = .5"},
		{"float no frac", "a = 5."},
		{"float 1.e2", "a = 1.e2"},
		{"float 1e", "a = 1e"},
		{"float 01.5", "a = 01.5"},
		{"Inf", "a = Inf"},
		{"NaN", "a = NaN"},
		{"True", "a = True"},
		{"date short", "a = 1987-7-05"},
		{"date bad month", "a = 1987-13-05"},
		{"date feb 30", "a = 1987-02-30"},
		{"date feb 29 nonleap", "a = 1900-02-29"},
		{"year zero", "a = 0000-01-01"},
		{"time no seconds", "a = 17:45"},
		{"leap second", "a = 1987-07-05T17:45:60Z"},
		{"hour 24", "a = 24:00:00"},
		{"offset hour", "a = 1987-07-05T17:45:00+24:00"},
		{"fraction empty", "a = 17:45:00."},
		{"arabic digits", "a = \u0661\u0662"},
		{"arabic date", "a = \u0661\u0662\u0663\u0664-01-01"},
		{"space no time", "a = 1987-07-05 17"},
		{"key empty", "= 1"},
		{"bare key unicode", "é = 1"},
		{"tab in literal ok but ctrl bad", "a = '\x01'"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			root, err := Parse([]byte(tc.in))
			if err == nil {
				t.Fatalf("Parse(%q) succeeded: %s", tc.in, root.AppendJSON(nil))
			}
			if _, ok := err.(*SyntaxError); !ok {
				t.Fatalf("error type %T, want *SyntaxError", err)
			}
		})
	}
}

func TestSyntaxErrorPosition(t *testing.T) {
	_, err := Parse([]byte("a = 1\nb = \n"))
	se, ok := err.(*SyntaxError)
	if !ok {
		t.Fatalf("got %v", err)
	}
	if se.Line < 2 {
		t.Errorf("Line = %d, want >= 2", se.Line)
	}
	if se.Error() == "" {
		t.Error("empty message")
	}
}

func TestDeepNesting(t *testing.T) {
	doc := ""
	for i := 0; i < 500; i++ {
		doc += "["
	}
	doc += "1"
	for i := 0; i < 500; i++ {
		doc += "]"
	}
	if _, err := Parse([]byte("a = " + doc)); err != nil {
		t.Fatal(err)
	}
}
