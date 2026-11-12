package tagged_test

import (
	"testing"

	"example.com/toml"
	"example.com/toml/tagged"
)

func TestMarshalEscapesAndOrder(t *testing.T) {
	root := toml.NewTable()
	root.Set("é", &toml.Value{Type: toml.TypeString, Text: "x"})
	root.Set("B", &toml.Value{Type: toml.TypeString, Text: "\"\\\b\f\n\r\t\x01\x7f é"})
	root.Set("a", toml.NewArray())
	want := `{"B":{"type":"string","value":"\"\\\b\f\n\r\t\u0001` + "\x7f é" + `"},"a":[],"é":{"type":"string","value":"x"}}`
	if got := string(tagged.Marshal(root)); got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
}

func TestUnmarshal(t *testing.T) {
	in := ` { "t" : { "value" : {"type":"string","value":"b"}, "type" : {"type":"string","value":"a"} },
	  "v": {"value":"1.5","type":"float"}, "arr": [ ] } `
	root, err := tagged.Unmarshal([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := root.Lookup("t"); !ok {
		t.Fatal("missing t")
	}
	if n, _ := root.Lookup("t"); func() bool { _, isTable := n.(*toml.Table); return !isTable }() {
		t.Error("t should be a table, not a value node")
	}
	if n, _ := root.Lookup("v"); n.(*toml.Value).Type != toml.TypeFloat {
		t.Error("v should be a float")
	}
}

func TestUnmarshalErrors(t *testing.T) {
	for _, in := range []string{``, `[]`, `{"a":1}`, `{"a":`} {
		if _, err := tagged.Unmarshal([]byte(in)); err == nil {
			t.Errorf("Unmarshal(%q) succeeded", in)
		}
	}
}
