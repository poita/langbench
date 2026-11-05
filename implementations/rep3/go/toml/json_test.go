package toml

import "testing"

func TestJSONEscapingAndOrder(t *testing.T) {
	root := NewTable()
	root.Set("é", NewInt(1))
	root.Set("a", NewString("q\"\\\b\f\n\r\t\x01\x7f é"))
	root.Set("A", NewInt(2))
	root.Set("", NewInt(3))
	got := string(root.AppendJSON(nil))
	want := `{"":{"type":"integer","value":"3"},"A":{"type":"integer","value":"2"},` +
		`"a":{"type":"string","value":"q\"\\\b\f\n\r\t\u0001` + "\x7f" + ` é"},"é":{"type":"integer","value":"1"}}`
	if got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
}

func TestParseJSON(t *testing.T) {
	in := ` { "b" : [ {"value":"1","type":"integer"} , {} , [] ] ,
	  "a":{"type":"string","value":"x\u00e9\ud83d\ude00\n\/"},
	  "t":{"type":{"type":"string","value":"a"},"value":{"type":"string","value":"b"}} } `
	root, err := ParseJSON([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	a, _ := root.Get("a")
	if a.Kind() != String || a.Text() != "xé😀\n/" {
		t.Errorf("a = %v %q", a.Kind(), a.Text())
	}
	tt, _ := root.Get("t")
	if !tt.IsTable() || tt.Len() != 2 {
		t.Errorf("t should be a table with keys type/value, got %v", tt.Kind())
	}
	b, _ := root.Get("b")
	if !b.IsArray() || b.Len() != 3 || b.Index(0).Kind() != Integer || !b.Index(1).IsTable() {
		t.Errorf("b mis-parsed")
	}
}

func TestParseJSONErrors(t *testing.T) {
	for _, in := range []string{``, `[]`, `{`, `{"a":}`, `{"a":1}`, `{} x`, `{"a":"\q"}`} {
		if _, err := ParseJSON([]byte(in)); err == nil {
			t.Errorf("ParseJSON(%q) succeeded", in)
		}
	}
}
