package toml_test

import (
	"testing"

	"example.com/toml"
	"example.com/toml/tagged"
)

func TestEncode(t *testing.T) {
	tests := []struct{ name, json, want string }{
		{"empty", `{}`, "\n"},
		{"example",
			`{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},"fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],"name":{"type":"string","value":"Tom"}}`,
			"dob = 1979-05-27T07:32:00-08:00\nname = \"Tom\"\n\n[db]\nenabled = true\nports = [8001, 8002]\n\n[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"banana\"\n"},
		{"first header no blank", `{"a":{"b":{}}}`, "[a]\n\n[a.b]\n"},
		{"empty array inline", `{"a":[],"b":[[],[{"type":"integer","value":"1"}]]}`, "a = []\nb = [[], [1]]\n"},
		{"mixed array inline", `{"a":[{"x":{"type":"integer","value":"1"}},{"type":"integer","value":"2"}]}`, "a = [{x = 1}, 2]\n"},
		{"key quoting", `{"a b":{"type":"string","value":"q\"\\\u0001\u007f\n\u00e9"},"":{"type":"bool","value":"true"}}`,
			"\"\" = true\n\"a b\" = \"q\\\"\\\\\\u0001\\u007f\\n\u00e9\"\n"},
		{"type key table", `{"t":{"type":{"type":"string","value":"a"},"value":{"type":"string","value":"b"}}}`,
			"[t]\ntype = \"a\"\nvalue = \"b\"\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			root, err := tagged.Unmarshal([]byte(tc.json))
			if err != nil {
				t.Fatal(err)
			}
			if got := string(toml.Encode(root)); got != tc.want {
				t.Errorf("got  %q\nwant %q", got, tc.want)
			}
		})
	}
}

// TestRoundTrip checks decode(encode(x)) == x on decoded documents.
func TestRoundTrip(t *testing.T) {
	docs := []string{
		"a = 1\nb = 'x\\y'\n[t]\nc = [1, 'two', {d = 3.5}]\n[[t.u]]\nv = 1979-05-27T07:32:00Z\n[[t.u]]\n[e.\"f g\"]\n",
		"x = \"\"\"\nline1\nline2\\\n   joined\"\"\"\nnan = nan\ninf = -inf\nz = -0.0\n",
		"\"\" = 0\n\"\\u0000\" = 1e-310\n",
	}
	for _, doc := range docs {
		root, err := toml.Parse([]byte(doc))
		if err != nil {
			t.Fatal(err)
		}
		want := tagged.Marshal(root)
		root2, err := toml.Parse(toml.Encode(root))
		if err != nil {
			t.Fatalf("re-parse of %q: %v", toml.Encode(root), err)
		}
		if got := tagged.Marshal(root2); string(got) != string(want) {
			t.Errorf("round trip changed tree\n got %s\nwant %s", got, want)
		}
	}
}
