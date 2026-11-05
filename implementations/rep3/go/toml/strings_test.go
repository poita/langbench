package toml

import "testing"

func TestStrings(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"basic", `"hello"`, "hello"},
		{"escapes", `"a\tb\n\\\"\b\f\r"`, "a\tb\n\\\"\b\f\r"},
		{"u escape", `"\u00e9\U0001F600"`, "é😀"},
		{"upper hex", `"\u00E9"`, "é"},
		{"nul", `"\u0000"`, "\x00"},
		{"literal", `'C:\path'`, `C:\path`},
		{"literal tab", "'a\tb'", "a\tb"},
		{"empty", `""`, ""},
		{"ml basic newline dropped", "\"\"\"\nx\ny\"\"\"", "x\ny"},
		{"ml basic crlf", "\"\"\"\r\nx\r\ny\"\"\"", "x\ny"},
		{"ml quotes", `"""a""b"""`, `a""b`},
		{"ml four quotes", `"""a""""`, `a"`},
		{"ml five quotes", `"""a"""""`, `a""`},
		{"ml line ending backslash", "\"\"\"a \\\n\n   b\"\"\"", "a b"},
		{"ml backslash trailing ws", "\"\"\"a\\  \n  b\"\"\"", "ab"},
		{"ml escape", `"""a\tb"""`, "a\tb"},
		{"ml literal", "'''\nx\\n\ny'''", "x\\n\ny"},
		{"ml literal quotes", `'''a''b''''`, `a''b'`},
		{"ml literal five", `'''a'''''`, `a''`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			root, err := Parse([]byte("k = " + tc.in))
			if err != nil {
				t.Fatal(err)
			}
			n, _ := root.Get("k")
			if n.Kind() != String || n.Text() != tc.want {
				t.Errorf("got %q (%v), want %q", n.Text(), n.Kind(), tc.want)
			}
		})
	}
}
