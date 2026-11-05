package toml

import "testing"

func encode(t *testing.T, js string) string {
	t.Helper()
	tbl, err := ParseTaggedJSON([]byte(js))
	if err != nil {
		t.Fatal(err)
	}
	return string(tbl.TOML())
}

func TestEncode(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", `{}`, "\n"},
		{"pairs sorted", `{"b":{"type":"integer","value":"1"},"a":{"type":"bool","value":"true"}}`, "a = true\nb = 1\n"},
		{"first header no blank", `{"a":{"b":{}}}`, "[a]\n\n[a.b]\n"},
		{"keys quoted", `{"a b":{"type":"integer","value":"1"},"":{"type":"integer","value":"2"},"é":{"type":"integer","value":"3"}}`,
			"\"\" = 2\n\"a b\" = 1\n\"é\" = 3\n"},
		{"string escapes", `{"s":{"type":"string","value":"a\"\\\u0008\t\n\u000c\r\u0001\u007f é"}}`,
			"s = \"a\\\"\\\\\\b\\t\\n\\f\\r\\u0001\\u007f é\"\n"},
		{"inline arrays", `{"a":[[{"type":"integer","value":"1"}],[],{"x":{"type":"integer","value":"1"}}]}`,
			"a = [[1], [], {x = 1}]\n"},
		{"array of tables", `{"p":{"type":"integer","value":"1"},"t":[{"x":{"type":"integer","value":"1"}},{}]}`,
			"p = 1\n\n[[t]]\nx = 1\n\n[[t]]\n"},
		{"nested aot path", `{"a":{"b":[{"c":{}}]}}`, "[a]\n\n[[a.b]]\n\n[a.b.c]\n"},
		{"pairs before headers", `{"z":{"k":{"type":"integer","value":"1"}},"y":{"type":"float","value":"nan"}}`,
			"y = nan\n\n[z]\nk = 1\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := encode(t, tc.in); got != tc.want {
				t.Errorf("got %q\nwant %q", got, tc.want)
			}
		})
	}
}

// TestRoundTrip checks decode(encode(x)) == x on documents with awkward shape.
func TestRoundTrip(t *testing.T) {
	docs := []string{
		"a = 1\n[b]\n[[c]]\nx = [1, 'two', {y = 3}]\n[[c]]\n[c.d]\n",
		"\"weird key\\n\" = \"\\u0000\\u007f\"\nf = [1.5, inf, -inf, nan, 5e-324]\n",
		"d = [1979-05-27, 07:32:00.5, 1979-05-27T07:32:00Z, 1979-05-27T07:32:00]\n",
		"[a.b.c]\nx = 1\n[a.b.d]\n",
		"a = []\nb = [{}]\nc = {}\n",
	}
	for _, d := range docs {
		first, err := Parse([]byte(d))
		if err != nil {
			t.Fatalf("%q: %v", d, err)
		}
		js := first.TaggedJSON()
		back, err := ParseTaggedJSON(js)
		if err != nil {
			t.Fatal(err)
		}
		again, err := Parse(back.TOML())
		if err != nil {
			t.Fatalf("re-parse of %q failed: %v", back.TOML(), err)
		}
		if got := string(again.TaggedJSON()); got != string(js) {
			t.Errorf("round trip of %q\n got %s\nwant %s", d, got, js)
		}
	}
}
