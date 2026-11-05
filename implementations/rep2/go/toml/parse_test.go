package toml

import "testing"

// decode parses doc and returns its tagged JSON, or "error".
func decode(t *testing.T, doc string) string {
	t.Helper()
	root, err := Parse([]byte(doc))
	if err != nil {
		return "error"
	}
	return string(MarshalTaggedJSON(root))
}

func TestParseValid(t *testing.T) {
	cases := []struct{ name, doc, want string }{
		{"empty", "", `{}`},
		{"string", `a = "x"`, `{"a":{"type":"string","value":"x"}}`},
		{"literal", `a = 'C:\x'`, `{"a":{"type":"string","value":"C:\\x"}}`},
		{"escapes", `a = "\t\u00e9\U0001F600\\"`, "{\"a\":{\"type\":\"string\",\"value\":\"\\t\u00e9\U0001F600\\\\\"}}"},
		{"nul", `a = "\u0000"`, `{"a":{"type":"string","value":"\u0000"}}`},
		{"ml first newline", "a = \"\"\"\nx\ny\"\"\"", `{"a":{"type":"string","value":"x\ny"}}`},
		{"ml crlf", "a = \"\"\"\r\nx\r\ny\"\"\"", `{"a":{"type":"string","value":"x\ny"}}`},
		{"ml line ending backslash", "a = \"\"\"x \\\n   y\"\"\"", `{"a":{"type":"string","value":"x y"}}`},
		{"ml quotes", `a = """a""""`, `{"a":{"type":"string","value":"a\""}}`},
		{"ml literal quotes", "a = '''a'''''", `{"a":{"type":"string","value":"a''"}}`},
		{"int", `a = -17`, `{"a":{"type":"integer","value":"-17"}}`},
		{"int underscore", `a = 1_000`, `{"a":{"type":"integer","value":"1000"}}`},
		{"hex", `a = 0xDEAD_beef`, `{"a":{"type":"integer","value":"3735928559"}}`},
		{"octal", `a = 0o17`, `{"a":{"type":"integer","value":"15"}}`},
		{"binary", `a = 0b101`, `{"a":{"type":"integer","value":"5"}}`},
		{"int min", `a = -9223372036854775808`, `{"a":{"type":"integer","value":"-9223372036854775808"}}`},
		{"int max", `a = 9223372036854775807`, `{"a":{"type":"integer","value":"9223372036854775807"}}`},
		{"float", `a = 3.1415`, `{"a":{"type":"float","value":"3.1415000000000002e+00"}}`},
		{"float neg zero", `a = -0.0`, `{"a":{"type":"float","value":"-0.0000000000000000e+00"}}`},
		{"float exp", `a = 6.626e-34`, `{"a":{"type":"float","value":"6.6259999999999998e-34"}}`},
		{"float subnormal", `a = 5e-324`, `{"a":{"type":"float","value":"4.9406564584124654e-324"}}`},
		{"float overflow", `a = 1e999`, `{"a":{"type":"float","value":"inf"}}`},
		{"float underflow", `a = 1e-999`, `{"a":{"type":"float","value":"0.0000000000000000e+00"}}`},
		{"inf", `a = -inf`, `{"a":{"type":"float","value":"-inf"}}`},
		{"nan", `a = -nan`, `{"a":{"type":"float","value":"nan"}}`},
		{"bool", `a = true`, `{"a":{"type":"bool","value":"true"}}`},
		{"datetime z", `a = 1987-07-05 17:45:00z`, `{"a":{"type":"datetime","value":"1987-07-05T17:45:00Z"}}`},
		{"datetime frac", `a = 1987-07-05T17:45:56.600+08:00`, `{"a":{"type":"datetime","value":"1987-07-05T17:45:56.6+08:00"}}`},
		{"datetime -00:00", `a = 1979-05-27t07:32:00-00:00`, `{"a":{"type":"datetime","value":"1979-05-27T07:32:00Z"}}`},
		{"datetime local", `a = 1979-05-27T07:32:00.000`, `{"a":{"type":"datetime-local","value":"1979-05-27T07:32:00"}}`},
		{"date then comment", `a = 1979-05-27 # c`, `{"a":{"type":"date-local","value":"1979-05-27"}}`},
		{"time", `a = 07:32:00.5`, `{"a":{"type":"time-local","value":"07:32:00.5"}}`},
		{"leap day", `a = 2000-02-29`, `{"a":{"type":"date-local","value":"2000-02-29"}}`},
		{"array", "a = [1, 'x', [2],\n # c\n]", `{"a":[{"type":"integer","value":"1"},{"type":"string","value":"x"},[{"type":"integer","value":"2"}]]}`},
		{"inline", `a = {b = 1, c.d = 2}`, `{"a":{"b":{"type":"integer","value":"1"},"c":{"d":{"type":"integer","value":"2"}}}}`},
		{"inline array newline", "a = {b = [\n1,\n]}", `{"a":{"b":[{"type":"integer","value":"1"}]}}`},
		{"dotted", "a.b = 1\na.c = 2", `{"a":{"b":{"type":"integer","value":"1"},"c":{"type":"integer","value":"2"}}}`},
		{"quoted key", `"a b".'c' = 1`, `{"a b":{"c":{"type":"integer","value":"1"}}}`},
		{"empty key", `"" = 1`, `{"":{"type":"integer","value":"1"}}`},
		{"header", "[a.b]\nc = 1", `{"a":{"b":{"c":{"type":"integer","value":"1"}}}}`},
		{"header then super", "[a.b]\n[a]\nc = 1", `{"a":{"b":{},"c":{"type":"integer","value":"1"}}}`},
		{"aot", "[[a]]\nx = 1\n[a.s]\ny = 2\n[[a]]\nx = 3", `{"a":[{"s":{"y":{"type":"integer","value":"2"}},"x":{"type":"integer","value":"1"}},{"x":{"type":"integer","value":"3"}}]}`},
		{"through dotted", "[f]\na.c = 1\n[f.a.t]\nx = 1", `{"f":{"a":{"c":{"type":"integer","value":"1"},"t":{"x":{"type":"integer","value":"1"}}}}}`},
		{"crlf", "a = 1\r\nb = 2\r\n", `{"a":{"type":"integer","value":"1"},"b":{"type":"integer","value":"2"}}`},
		{"sorted keys", "b = 1\nA = 1\n\"é\" = 1\na = 1", `{"A":{"type":"integer","value":"1"},"a":{"type":"integer","value":"1"},"b":{"type":"integer","value":"1"},"é":{"type":"integer","value":"1"}}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := decode(t, c.doc); got != c.want {
				t.Errorf("doc %q\n got %s\nwant %s", c.doc, got, c.want)
			}
		})
	}
}

func TestParseInvalid(t *testing.T) {
	docs := map[string]string{
		"bom":                 "\xef\xbb\xbfa = 1",
		"bad utf8":            "a = \"\xff\"",
		"lone cr":             "a = 1\rb = 2",
		"cr in string":        "a = \"x\ry\"",
		"nul":                 "a = \"x\x00\"",
		"del in comment":      "# \x7f",
		"no value":            "a =",
		"no equals":           "a",
		"trailing garbage":    "a = 1 b",
		"duplicate":           "a = 1\na = 2",
		"dup via table":       "[a]\n[a]",
		"table after dotted":  "a.b = 1\n[a]",
		"dotted into header":  "[a.b.c]\n[a]\nb.c.t = 1",
		"target dotted":       "[f]\na.c = 1\n[f.a]",
		"inline reopen":       "a = {b = 1}\n[a]",
		"inline extend":       "a = {b = 1}\na.c = 2",
		"inline nested":       "a = {b = {c = 1}}\n[a.b.d]",
		"inline trailing ,":   "a = {b = 1,}",
		"inline newline":      "a = {b = 1,\nc = 2}",
		"aot over array":      "a = [{b = 1}]\n[[a]]",
		"header through val":  "a = 1\n[a.b]",
		"spaced aot":          "[ [a] ]",
		"half spaced aot":     "[[a] ]",
		"array double comma":  "a = [1,,2]",
		"array lead comma":    "a = [,1]",
		"leading zero":        "a = 01",
		"plus leading zero":   "a = +01",
		"underscore trailing": "a = 1_",
		"underscore double":   "a = 1__0",
		"upper hex prefix":    "a = 0X1",
		"signed hex":          "a = -0x1",
		"int overflow":        "a = 9223372036854775808",
		"hex overflow":        "a = 0xFFFFFFFFFFFFFFFF",
		"neg overflow":        "a = -9223372036854775809",
		"float no int":        "a = .5",
		"float no frac":       "a = 5.",
		"float 1.e2":          "a = 1.e2",
		"float 1e":            "a = 1e",
		"upper inf":           "a = INF",
		"upper true":          "a = True",
		"year zero":           "a = 0000-01-01",
		"month 13":            "a = 2000-13-01",
		"feb 29 non-leap":     "a = 1900-02-29",
		"leap second":         "a = 00:00:60",
		"no seconds":          "a = 17:45",
		"short field":         "a = 1987-7-05",
		"arabic digits":       "a = \u0661\u0662",
		"bad escape":          `a = "\q"`,
		"surrogate escape":    `a = "\ud800"`,
		"big escape":          `a = "\U00110000"`,
		"newline in string":   "a = \"x\ny\"",
		"six quotes":          `a = """x""""""`,
		"bad line backslash":  "a = \"\"\"x\\ y\"\"\"",
		"ml key":              `"""a""" = 1`,
		"bare key unicode":    "é = 1",
		"unterminated":        `a = "x`,
		"unterminated array":  "a = [1",
	}
	for name, doc := range docs {
		t.Run(name, func(t *testing.T) {
			if root, err := Parse([]byte(doc)); err == nil {
				t.Errorf("expected error for %q, got %s", doc, MarshalTaggedJSON(root))
			}
		})
	}
}

func TestErrorPosition(t *testing.T) {
	_, err := Parse([]byte("a = 1\nb = ?\n"))
	e, ok := err.(*Error)
	if !ok {
		t.Fatalf("want *Error, got %T", err)
	}
	if e.Line != 2 || e.Col != 5 {
		t.Errorf("position = %d:%d, want 2:5", e.Line, e.Col)
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
	if got := decode(t, "a = "+doc); got == "error" {
		t.Error("deeply nested array rejected")
	}
}
