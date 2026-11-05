package toml

import "testing"

func TestTaggedJSONEscaping(t *testing.T) {
	tbl := NewTable()
	tbl.Set("k\x01", &Value{String, "\"\\\b\f\n\r\t\x00\x1f\x7f é"})
	got := string(tbl.TaggedJSON())
	want := `{"k\u0001":{"type":"string","value":"\"\\\b\f\n\r\t\u0000\u001f` + "\x7f é" + `"}}`
	if got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
}

func TestParseTaggedJSON(t *testing.T) {
	src := ` { "b" : [ {"value":"1","type":"integer"} , { } ],
	  "a" : { "type" : { "value": "x", "type": "string" }, "s": {"type":"string","value":"\u00e9\ud83d\ude00\/\n"} } } `
	tbl, err := ParseTaggedJSON([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	want := `{"a":{"s":{"type":"string","value":"é😀/\n"},"type":{"type":"string","value":"x"}},"b":[{"type":"integer","value":"1"},{}]}`
	if got := string(tbl.TaggedJSON()); got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
}

func TestParseTaggedJSONErrors(t *testing.T) {
	for _, in := range []string{``, `[]`, `{`, `{"a":}`, `{"a":{"type":"integer","value":"1"}`, `{} x`, `{"a":"b"}`, `{"a":"\q"}`} {
		if _, err := ParseTaggedJSON([]byte(in)); err == nil {
			t.Errorf("ParseTaggedJSON(%q) succeeded, want error", in)
		}
	}
}
