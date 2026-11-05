package toml

import "testing"

// decode parses src and returns the tagged JSON, or "error".
func decode(t *testing.T, src string) string {
	t.Helper()
	tbl, err := Parse([]byte(src))
	if err != nil {
		return "error"
	}
	return string(tbl.TaggedJSON())
}

func TestDecodeValid(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", "", `{}`},
		{"comment only", "# hi\n", `{}`},
		{"pair", "a = 1", `{"a":{"type":"integer","value":"1"}}`},
		{"crlf", "a = 1\r\nb = 2\r\n", `{"a":{"type":"integer","value":"1"},"b":{"type":"integer","value":"2"}}`},
		{"quoted keys equal", "\"a\" = 1\n", `{"a":{"type":"integer","value":"1"}}`},
		{"dotted", "a.b.c = true", `{"a":{"b":{"c":{"type":"bool","value":"true"}}}}`},
		{"dotted spaces", "a . b = true", `{"a":{"b":{"type":"bool","value":"true"}}}`},
		{"table", "[a]\nb = 1\n[a.c]\nd = 2", `{"a":{"b":{"type":"integer","value":"1"},"c":{"d":{"type":"integer","value":"2"}}}}`},
		{"array of tables", "[[a]]\nx=1\n[a.b]\ny=2\n[[a]]\nx=3", `{"a":[{"b":{"y":{"type":"integer","value":"2"}},"x":{"type":"integer","value":"1"}},{"x":{"type":"integer","value":"3"}}]}`},
		{"mixed array", "a = [1, 'x', [true],]", `{"a":[{"type":"integer","value":"1"},{"type":"string","value":"x"},[{"type":"bool","value":"true"}]]}`},
		{"array comments", "a = [\n 1, # one\n 2\n]", `{"a":[{"type":"integer","value":"1"},{"type":"integer","value":"2"}]}`},
		{"inline table", "a = {b = 1, c.d = 2}", `{"a":{"b":{"type":"integer","value":"1"},"c":{"d":{"type":"integer","value":"2"}}}}`},
		{"inline with multiline array", "a = { b = [\n1\n]}", `{"a":{"b":[{"type":"integer","value":"1"}]}}`},
		{"header through dotted", "[f]\na.c = 1\n[f.a.t]\nx = 1", `{"f":{"a":{"c":{"type":"integer","value":"1"},"t":{"x":{"type":"integer","value":"1"}}}}}`},
		{"type value keys", "type = {}\nvalue = {}", `{"type":{},"value":{}}`},
		{"sorted keys", "b=1\nA=1\na=1\n\"é\"=1", `{"A":{"type":"integer","value":"1"},"a":{"type":"integer","value":"1"},"b":{"type":"integer","value":"1"},"é":{"type":"integer","value":"1"}}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := decode(t, tc.in); got != tc.want {
				t.Errorf("decode(%q)\n got %s\nwant %s", tc.in, got, tc.want)
			}
		})
	}
}

func TestDecodeInvalid(t *testing.T) {
	tests := map[string]string{
		"bom":                 "\xef\xbb\xbfa = 1",
		"bad utf8":            "a = \"\xff\"",
		"surrogate utf8":      "a = \"\xed\xa0\x80\"",
		"lone CR":             "a = 1\rb = 2",
		"CR in comment":       "# a\rb\n",
		"NUL in comment":      "# a\x00\n",
		"DEL in string":       "a = \"\x7f\"",
		"no value":            "a =",
		"no equals":           "a 1",
		"trailing junk":       "a = 1 b",
		"duplicate key":       "a = 1\na = 2",
		"duplicate via dot":   "a.b = 1\na.b = 2",
		"table twice":         "[a]\n[a]",
		"table after dotted":  "a.b = 1\n[a]",
		"header on dotted":    "[f]\na.c = 1\n[f.a]",
		"dotted into header":  "[a.b]\n[a]\nb.c = 1",
		"extend inline":       "a = {}\n[a.b]",
		"extend inline dot":   "a = {b = 1}\na.c = 2",
		"inline nested seal":  "a = {b = {c = 1}}\n[a.b.d]",
		"inline trailing ,":   "a = {b = 1,}",
		"inline newline":      "a = {b = 1,\nc = 2}",
		"inline comment":      "a = {b = 1 # x\n}",
		"array double comma":  "a = [1,,2]",
		"array leading comma": "a = [,1]",
		"aot over table":      "[a]\n[[a]]",
		"aot over literal":    "a = [{b=1}]\n[[a]]",
		"into array literal":  "a = [{b=1}]\n[a.c]",
		"spaced aot":          "[ [a] ]",
		"half spaced aot":     "[[a] ]",
		"empty key part":      "a..b = 1",
		"multiline key":       "\"\"\"a\"\"\" = 1",
		"bad escape":          `a = "\q"`,
		"surrogate escape":    `a = "\ud800"`,
		"big escape":          `a = "\U00110000"`,
		"short escape":        `a = "\u12"`,
		"newline in string":   "a = \"x\ny\"",
		"unterminated":        `a = "x`,
		"six quotes":          `a = """x""""""`,
		"literal newline":     "a = 'x\ny'",
		"leading zero":        "a = 01",
		"signed hex":          "a = -0x1",
		"upper prefix":        "a = 0X1",
		"trailing underscore": "a = 1_",
		"double underscore":   "a = 1__0",
		"overflow":            "a = 9223372036854775808",
		"hex overflow":        "a = 0xFFFFFFFFFFFFFFFF",
		"neg overflow":        "a = -9223372036854775809",
		"float no int":        "a = .5",
		"float no frac":       "a = 5.",
		"float 1.e2":          "a = 1.e2",
		"float no exp":        "a = 1e",
		"upper inf":           "a = Inf",
		"upper true":          "a = True",
		"arabic digits":       "a = ١٢٣",
		"arabic date":         "a = ١٩٧٩-٠٥-٢٧",
		"short month":         "a = 1987-7-05",
		"bad day":             "a = 2021-02-29",
		"month 13":            "a = 2021-13-01",
		"year 0":              "a = 0000-01-01",
		"leap second":         "a = 1979-05-27T07:32:60Z",
		"no seconds":          "a = 07:32",
		"hour 24":             "a = 24:00:00",
		"offset hour 24":      "a = 1979-05-27T07:32:00+24:00",
		"time offset":         "a = 07:32:00Z",
		"empty frac":          "a = 07:32:00.",
		"tab separator":       "a = 1979-05-27\t07:32:00",
	}
	for name, in := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := Parse([]byte(in)); err == nil {
				t.Errorf("Parse(%q) succeeded, want error", in)
			} else if _, ok := err.(*SyntaxError); !ok {
				t.Errorf("error type = %T, want *SyntaxError", err)
			}
		})
	}
}

func TestSyntaxErrorLine(t *testing.T) {
	_, err := Parse([]byte("a = 1\nb = 2\nc ="))
	se, ok := err.(*SyntaxError)
	if !ok {
		t.Fatalf("got %v", err)
	}
	if se.Line != 3 {
		t.Errorf("Line = %d, want 3", se.Line)
	}
}

func TestDeepNesting(t *testing.T) {
	src := "a = "
	for i := 0; i < 500; i++ {
		src += "["
	}
	for i := 0; i < 500; i++ {
		src += "]"
	}
	if got := decode(t, src); got == "error" {
		t.Error("deeply nested array rejected")
	}
}
