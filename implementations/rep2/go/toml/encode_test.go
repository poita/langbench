package toml

import "testing"

func tagged(t *testing.T, js string) string {
	t.Helper()
	root, err := ParseTaggedJSON([]byte(js))
	if err != nil {
		t.Fatal(err)
	}
	out, err := MarshalTOML(root)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func TestMarshalTOML(t *testing.T) {
	const doc = `{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},
	"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},
	"fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],
	"name":{"type":"string","value":"Tom"}}`
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
	if got := tagged(t, doc); got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestMarshalTOMLShapes(t *testing.T) {
	cases := []struct{ name, js, want string }{
		{"empty root", `{}`, "\n"},
		{"first header no blank line", `{"a":{"b":{}}}`, "[a]\n\n[a.b]\n"},
		{"empty array inline", `{"a":[],"b":{"c":[[],[{"x":{"type":"integer","value":"1"}}]]}}`, "a = []\n\n[b]\nc = [[], [{x = 1}]]\n"},
		{"mixed array inline", `{"a":[{},{"type":"integer","value":"1"}]}`, "a = [{}, 1]\n"},
		{"key quoting", `{"a b":{"type":"bool","value":"false"},"":{"type":"bool","value":"true"},"é":{"type":"bool","value":"true"}}`, "\"\" = true\n\"a b\" = false\n\"é\" = true\n"},
		{"string quoting", `{"s":{"type":"string","value":"a\"\\\b\t\n\f\r\u0001\u007f é"}}`, "s = \"a\\\"\\\\\\b\\t\\n\\f\\r\\u0001\\u007f é\"\n"},
		{"nested path quoting", `{"a.b":{"c d":{"x":{"type":"integer","value":"1"}}}}`, "[\"a.b\"]\n\n[\"a.b\".\"c d\"]\nx = 1\n"},
		{"aot nested", `{"a":[{"b":[{"x":{"type":"integer","value":"1"}}]}]}`, "[[a]]\n\n[[a.b]]\nx = 1\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := tagged(t, c.js); got != c.want {
				t.Errorf("got %q\nwant %q", got, c.want)
			}
		})
	}
}

func TestMarshalTOMLRejectsNonTable(t *testing.T) {
	if _, err := MarshalTOML(NewString("x")); err == nil {
		t.Error("expected error")
	}
}

// TestRoundTrip checks decode(encode(x)) == x on a document touching every type.
func TestRoundTrip(t *testing.T) {
	doc := "s = \"a\\u0000b\"\ni = -5\nf = 1e100\nn = nan\nd = 1979-05-27T07:32:00.123Z\nl = 1979-05-27T07:32:00\n" +
		"dl = 1979-05-27\ntl = 07:32:00\nx = [1, [2, 3], {a = 1}]\n\"k k\".z = 1\n[t]\nu = {v = {}}\n[[t.a]]\nq = 1\n[[t.a]]\n"
	root, err := Parse([]byte(doc))
	if err != nil {
		t.Fatal(err)
	}
	want := string(MarshalTaggedJSON(root))
	out, err := MarshalTOML(root)
	if err != nil {
		t.Fatal(err)
	}
	root2, err := Parse(out)
	if err != nil {
		t.Fatalf("re-parse failed: %v\n%s", err, out)
	}
	if got := string(MarshalTaggedJSON(root2)); got != want {
		t.Errorf("round trip mismatch\n got %s\nwant %s", got, want)
	}
}
