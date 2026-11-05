package toml

import (
	"math"
	"strings"
	"testing"
)

func encodeFromJSON(t *testing.T, in string) string {
	t.Helper()
	root, err := ParseJSON([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	return string(root.AppendTOML(nil))
}

func TestEncodeWorkedExample(t *testing.T) {
	in := `{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},"fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],"name":{"type":"string","value":"Tom"}}`
	want := `dob = 1979-05-27T07:32:00-08:00
name = "Tom"

[db]
enabled = true
ports = [8001, 8002]

[[fruit]]
name = "apple"

[[fruit]]
name = "banana"
`
	if got := encodeFromJSON(t, in); got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestEncodeShapes(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", `{}`, "\n"},
		{"first header no blank", `{"a":{"b":{}}}`, "[a]\n\n[a.b]\n"},
		{"empty array inline", `{"a":[]}`, "a = []\n"},
		{"mixed array inline", `{"a":[{"x":{"type":"integer","value":"1"}},{"type":"integer","value":"2"}]}`, "a = [{x = 1}, 2]\n"},
		{"nested arrays", `{"a":[[{"type":"integer","value":"1"}],[]]}`, "a = [[1], []]\n"},
		{"empty inline table in array", `{"a":[{}]}`, "\n[[a]]\n"[1:]},
		{"quoted keys", `{"a b":{"type":"integer","value":"1"},"":{"type":"integer","value":"2"}}`, "\"\" = 2\n\"a b\" = 1\n"},
		{"quoted header", `{"x y":{"k":{"type":"integer","value":"1"}}}`, "[\"x y\"]\nk = 1\n"},
		{"string escapes", `{"s":{"type":"string","value":"\"\\\b\t\n\f\r\u0001\u007f\u00e9"}}`, "s = \"\\\"\\\\\\b\\t\\n\\f\\r\\u0001\\u007f\u00e9\"\n"},
		{"pairs before headers", `{"z":{"type":"integer","value":"1"},"a":{"k":{"type":"integer","value":"1"}}}`, "z = 1\n\n[a]\nk = 1\n"},
		{"aot nested", `{"a":[{"b":[{"c":{"type":"integer","value":"1"}}]}]}`, "[[a]]\n\n[[a.b]]\nc = 1\n"},
		{"floats verbatim", `{"f":{"type":"float","value":"-inf"},"g":{"type":"float","value":"1.0000000000000000e+00"}}`, "f = -inf\ng = 1.0000000000000000e+00\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := encodeFromJSON(t, tc.in); got != tc.want {
				t.Errorf("got:\n%q\nwant:\n%q", got, tc.want)
			}
		})
	}
}

// TestRoundTrip checks decode(encode(x)) == x for trees built from documents.
func TestRoundTrip(t *testing.T) {
	docs := []string{
		"a = 1\nb = [1, 2.5, \"x\", [true], {c = 1}]\n[t]\nk = 1979-05-27T07:32:00Z\n[[t.u]]\nx = 1\n[[t.u]]\n[t.u.v]\ny = 'q'\n",
		"\"a.b\" = 1\n\"\" = 2\n[\"x y\".z]\nk = \"\\u0000\\u007f\"\n",
		"empty = []\ne2 = {}\n[e3]\n[e4.e5]\nf = [inf, -inf, nan, 0.1]\n",
		"d = 1987-07-05\nt = 17:45:00.123\nl = 1987-07-05T17:45:00\ns = \"\"\"\nmulti\nline\"\"\"\n",
		"a = [{b = 1}, {c = 2}]\n[[x]]\n[[x.y]]\n[[x.y]]\n",
	}
	for _, doc := range docs {
		root, err := Parse([]byte(doc))
		if err != nil {
			t.Fatalf("%q: %v", doc, err)
		}
		j1 := root.AppendJSON(nil)
		toml := root.AppendTOML(nil)
		again, err := Parse(toml)
		if err != nil {
			t.Fatalf("re-parse of\n%s\n: %v", toml, err)
		}
		if j2 := again.AppendJSON(nil); string(j1) != string(j2) {
			t.Errorf("round trip mismatch for %q\nTOML:\n%s\n%s\n%s", doc, toml, j1, j2)
		}
		viaJSON, err := ParseJSON(j1)
		if err != nil {
			t.Fatal(err)
		}
		if string(viaJSON.AppendTOML(nil)) != string(toml) {
			t.Errorf("JSON-derived tree encodes differently for %q", doc)
		}
	}
}

func TestBuildTree(t *testing.T) {
	root := NewTable()
	root.Set("name", NewString("x"))
	root.Set("n", NewInt(3))
	root.Set("f", NewFloat(math.Inf(1)))
	root.Set("list", NewArray(NewInt(1), NewBool(false)))
	sub := NewTable()
	sub.Set("k", NewString("v"))
	root.Set("sub", sub)
	got := string(root.AppendTOML(nil))
	want := "f = inf\nlist = [1, false]\nn = 3\nname = \"x\"\n\n[sub]\nk = \"v\"\n"
	if got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
	if !strings.HasSuffix(got, "\n") {
		t.Error("missing trailing newline")
	}
}
