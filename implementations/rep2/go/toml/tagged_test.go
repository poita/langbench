package toml

import "testing"

func TestJSONEscaping(t *testing.T) {
	root := NewTable()
	root.Set("k\"\x01", NewString("a\\b\x08\x0c\n\r\t\x1f\x7f é"))
	got := string(MarshalTaggedJSON(root))
	want := "{\"k\\\"\\u0001\":{\"type\":\"string\",\"value\":\"a\\\\b\\b\\f\\n\\r\\t\\u001f\x7f é\"}}"
	if got != want {
		t.Errorf("got %s\nwant %s", got, want)
	}
}

func TestParseTaggedJSON(t *testing.T) {
	in := ` { "b" : { "value" : "1" , "type":"integer" } ,
	  "a": [ {"type":"string","value":"\u00e9\ud83d\ude00\n"}, [] , {} ],
	  "t": {"type":{"type":"string","value":"x"},"value":{"type":"string","value":"y"}} } `
	root, err := ParseTaggedJSON([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	if root.Get("b").Kind() != KindInteger || root.Get("b").Text() != "1" {
		t.Error("value node not recognised")
	}
	if s := root.Get("a").At(0).Text(); s != "é😀\n" {
		t.Errorf("string = %q", s)
	}
	if !root.Get("a").At(1).IsArray() || !root.Get("a").At(2).IsTable() {
		t.Error("empty containers")
	}
	if !root.Get("t").IsTable() || root.Get("t").Get("type").Kind() != KindString {
		t.Error("table with type/value keys misread")
	}
}

func TestParseTaggedJSONErrors(t *testing.T) {
	for _, in := range []string{``, `[]`, `"x"`, `{"a":}`, `{"a":{"type":"string","value":"x"}`, `{} x`, `{"a":"\q"}`} {
		if _, err := ParseTaggedJSON([]byte(in)); err == nil {
			t.Errorf("expected error for %q", in)
		}
	}
}
