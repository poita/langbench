package toml

import "testing"

func TestStrings(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"basic", `a = "x\ty\u00e9\U0001F600\\\""`, "x\ty\u00e9\U0001F600\\\""},
		{"nul escape", `a = "\u0000"`, "\x00"},
		{"literal", `a = 'C:\path\n'`, `C:\path\n`},
		{"ml basic first newline", "a = \"\"\"\nx\ny\"\"\"", "x\ny"},
		{"ml basic crlf", "a = \"\"\"\r\nx\r\ny\"\"\"", "x\ny"},
		{"ml basic quotes", `a = """a""b""""`, `a""b"`},
		{"ml basic five quotes", `a = """a"""""`, `a""`},
		{"ml line ending backslash", "a = \"\"\"x \\  \n\n   y\"\"\"", "x y"},
		{"ml literal", "a = '''\nx\\n 'y' ''z'''", "x\\n 'y' ''z"},
		{"ml literal four quotes", "a = '''x''''", "x'"},
		{"ml literal crlf", "a = '''x\r\ny'''", "x\ny"},
		{"unicode", "a = \"héllo ☃\"", "héllo ☃"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			tbl, err := Parse([]byte(tc.in))
			if err != nil {
				t.Fatal(err)
			}
			n, _ := tbl.Get("a")
			v, ok := n.(*Value)
			if !ok || v.Type != String {
				t.Fatalf("not a string: %#v", n)
			}
			if v.Text != tc.want {
				t.Errorf("got %q want %q", v.Text, tc.want)
			}
		})
	}
}
