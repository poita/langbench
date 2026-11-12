package toml_test

import (
	"testing"

	"example.com/toml"
	"example.com/toml/tagged"
)

func TestParseValid(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", ``, `{}`},
		{"string", `a = "x\ty\u00e9"`, "{\"a\":{\"type\":\"string\",\"value\":\"x\\ty\u00e9\"}}"},
		{"literal", `a = 'C:\n'`, `{"a":{"type":"string","value":"C:\\n"}}`},
		{"multiline trim", "a = \"\"\"\nx\\\n   y\"\"\"", `{"a":{"type":"string","value":"xy"}}`},
		{"multiline quotes", `a = """a""""`, `{"a":{"type":"string","value":"a\""}}`},
		{"multiline crlf", "a = '''\r\nx\r\ny'''", `{"a":{"type":"string","value":"x\ny"}}`},
		{"ints", "a = [0xf_f, 0o17, 0b11, -0, +5, 1_000]", `{"a":[{"type":"integer","value":"255"},{"type":"integer","value":"15"},{"type":"integer","value":"3"},{"type":"integer","value":"0"},{"type":"integer","value":"5"},{"type":"integer","value":"1000"}]}`},
		{"int min", `a = -9223372036854775808`, `{"a":{"type":"integer","value":"-9223372036854775808"}}`},
		{"floats", "a = [1.0, -0.0, 6.626e-34, 5e-324, inf, -nan, 1e400]", `{"a":[{"type":"float","value":"1.0000000000000000e+00"},{"type":"float","value":"-0.0000000000000000e+00"},{"type":"float","value":"6.6259999999999998e-34"},{"type":"float","value":"4.9406564584124654e-324"},{"type":"float","value":"inf"},{"type":"float","value":"nan"},{"type":"float","value":"inf"}]}`},
		{"datetimes", "a = 1987-07-05 17:45:00z\nb = 1979-05-27t07:32:00-00:00\nc = 1987-07-05T17:45:56.600+08:00\nd = 1979-05-27 # c\ne = 07:32:00.000\nf = 2000-01-01T00:00:00",
			`{"a":{"type":"datetime","value":"1987-07-05T17:45:00Z"},"b":{"type":"datetime","value":"1979-05-27T07:32:00Z"},"c":{"type":"datetime","value":"1987-07-05T17:45:56.6+08:00"},"d":{"type":"date-local","value":"1979-05-27"},"e":{"type":"time-local","value":"07:32:00"},"f":{"type":"datetime-local","value":"2000-01-01T00:00:00"}}`},
		{"dotted keys", "a.b = 1\na.c = 2\n[x]\ny.z = 3", `{"a":{"b":{"type":"integer","value":"1"},"c":{"type":"integer","value":"2"}},"x":{"y":{"z":{"type":"integer","value":"3"}}}}`},
		{"quoted keys", `"a b"."" = 1`, `{"a b":{"":{"type":"integer","value":"1"}}}`},
		{"array of tables", "[[a]]\nx = 1\n[a.b]\ny = 2\n[[a]]\nx = 3", `{"a":[{"b":{"y":{"type":"integer","value":"2"}},"x":{"type":"integer","value":"1"}},{"x":{"type":"integer","value":"3"}}]}`},
		{"through dotted", "[fruit]\napple.color = \"red\"\n[fruit.apple.texture]\nsmooth = true", `{"fruit":{"apple":{"color":{"type":"string","value":"red"},"texture":{"smooth":{"type":"bool","value":"true"}}}}}`},
		{"implicit then explicit", "[a.b]\n[a]\nx = 1", `{"a":{"b":{},"x":{"type":"integer","value":"1"}}}`},
		{"inline", "a = {b = 1, c.d = [\n 1, # x\n]}", `{"a":{"b":{"type":"integer","value":"1"},"c":{"d":[{"type":"integer","value":"1"}]}}}`},
		{"comments and crlf", "# c\r\na = 1 # d\r\n\r\n", `{"a":{"type":"integer","value":"1"}}`},
		{"nul escape", `a = "\u0000"`, `{"a":{"type":"string","value":"\u0000"}}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			root, err := toml.Parse([]byte(tc.in))
			if err != nil {
				t.Fatalf("Parse: %v", err)
			}
			if got := string(tagged.Marshal(root)); got != tc.want {
				t.Errorf("got  %s\nwant %s", got, tc.want)
			}
		})
	}
}

func TestParseInvalid(t *testing.T) {
	tests := map[string]string{
		"bom":                 "\xef\xbb\xbfa = 1",
		"bad utf8":            "a = \"\xff\"",
		"surrogate utf8":      "a = \"\xed\xa0\x80\"",
		"bare cr":             "a = 1\rb = 2",
		"cr in string":        "a = \"x\ry\"",
		"cr in comment":       "# x\ry\n",
		"control in comment":  "# \x01\n",
		"del in string":       "a = \"\x7f\"",
		"no value":            "a =",
		"trailing garbage":    "a = 1 b = 2",
		"dup key":             "a = 1\na = 2",
		"dup via dotted":      "a.b = 1\na = 2",
		"dup table":           "[a]\n[a]",
		"table after dotted":  "a.b = 1\n[a]",
		"header on dotted":    "[fruit]\napple.color = 1\n[fruit.apple]",
		"dotted into header":  "[a.b]\n[a]\nb.c = 1",
		"extend inline":       "a = {b = 1}\n[a.c]",
		"dotted into inline":  "a = {b = 1}\na.c = 2",
		"inline newline":      "a = {b = 1,\nc = 2}",
		"inline trailing":     "a = {b = 1,}",
		"array leading comma": "a = [,1]",
		"array double comma":  "a = [1,,2]",
		"extend array":        "a = [1]\n[[a]]",
		"extend static aot":   "a = [{b = 1}]\n[a.c]",
		"aot over table":      "[a]\n[[a]]",
		"leading zero":        "a = 01",
		"signed hex":          "a = -0x1",
		"upper hex prefix":    "a = 0X1",
		"int overflow":        "a = 9223372036854775808",
		"hex overflow":        "a = 0xFFFFFFFFFFFFFFFF",
		"trailing underscore": "a = 1_",
		"double underscore":   "a = 1__0",
		"float no int":        "a = .5",
		"float no frac":       "a = 5.",
		"float bad exp":       "a = 1e",
		"upper inf":           "a = Inf",
		"bool case":           "a = True",
		"short date":          "a = 1987-7-05",
		"bad day":             "a = 2023-02-29",
		"year zero":           "a = 0000-01-01",
		"leap second":         "a = 1990-01-01T00:00:60Z",
		"no seconds":          "a = 17:45",
		"bad offset":          "a = 1990-01-01T00:00:00+24:00",
		"arabic digits":       "a = \u0661\u0662",
		"bad escape":          `a = "\q"`,
		"surrogate escape":    `a = "\ud800"`,
		"big escape":          `a = "\U00110000"`,
		"newline in string":   "a = \"x\ny\"",
		"six quotes":          `a = """a""""""`,
		"ws in aot bracket":   "[ [a] ]",
		"split aot bracket":   "[[a] ]",
		"multiline key":       `""" a """ = 1`,
		"space in bare key":   "a b = 1",
		"unterminated array":  "a = [1",
		"line-ending junk":    "a = \"\"\"x\\ y\"\"\"",
	}
	for name, in := range tests {
		t.Run(name, func(t *testing.T) {
			if root, err := toml.Parse([]byte(in)); err == nil {
				t.Errorf("Parse(%q) succeeded: %s", in, tagged.Marshal(root))
			}
		})
	}
}

func TestSyntaxErrorLine(t *testing.T) {
	_, err := toml.Parse([]byte("a = 1\nb = 2\nc = \n"))
	se, ok := err.(*toml.SyntaxError)
	if !ok {
		t.Fatalf("error type %T", err)
	}
	if se.Line != 3 {
		t.Errorf("line = %d, want 3", se.Line)
	}
}

func TestDeepNesting(t *testing.T) {
	in := "a = "
	const depth = 500
	for i := 0; i < depth; i++ {
		in += "["
	}
	for i := 0; i < depth; i++ {
		in += "]"
	}
	if _, err := toml.Parse([]byte(in)); err != nil {
		t.Fatal(err)
	}
}

func TestLookup(t *testing.T) {
	root, err := toml.Parse([]byte("[[a]]\nx = 1\n[[a]]\nx = 2\n[b.c]\nd = 'v'"))
	if err != nil {
		t.Fatal(err)
	}
	n, ok := root.Lookup("a", "x")
	if !ok || n.(*toml.Value).Text != "2" {
		t.Errorf("a.x = %v, %v", n, ok)
	}
	n, ok = root.Lookup("b", "c", "d")
	if !ok || n.(*toml.Value).Type != toml.TypeString {
		t.Errorf("b.c.d = %v, %v", n, ok)
	}
	if _, ok := root.Lookup("b", "zzz"); ok {
		t.Error("found missing key")
	}
}
