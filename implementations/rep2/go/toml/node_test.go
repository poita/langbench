package toml

import (
	"math"
	"testing"
)

func TestNodeAccessors(t *testing.T) {
	root, err := Parse([]byte("i = 42\nf = 1.5\nb = true\ns = \"hi\"\nd = 1979-05-27\na = [1, 2]\n[t]\nx = 1"))
	if err != nil {
		t.Fatal(err)
	}
	if got := root.Get("i").Int64(); got != 42 {
		t.Errorf("Int64 = %d", got)
	}
	if got := root.Get("f").Float64(); got != 1.5 {
		t.Errorf("Float64 = %v", got)
	}
	if !root.Get("b").Bool() {
		t.Error("Bool = false")
	}
	if got := root.Get("s").Text(); got != "hi" {
		t.Errorf("Text = %q", got)
	}
	if k := root.Get("d").Kind(); k != KindDateLocal {
		t.Errorf("Kind = %v", k)
	}
	if root.Get("a").Len() != 2 || root.Get("a").At(1).Int64() != 2 {
		t.Error("array access")
	}
	if !root.Get("t").IsTable() || root.Get("missing") != nil {
		t.Error("table access")
	}
	keys := root.Keys()
	if len(keys) != 7 || keys[0] != "a" || keys[6] != "t" {
		t.Errorf("Keys = %v", keys)
	}
}

func TestBuilders(t *testing.T) {
	root := NewTable()
	root.Set("n", NewInteger(-3))
	root.Set("f", NewFloat(math.Inf(-1)))
	root.Set("l", NewArray(NewBool(true), NewString("x")))
	got := string(MarshalTaggedJSON(root))
	want := `{"f":{"type":"float","value":"-inf"},"l":[{"type":"bool","value":"true"},{"type":"string","value":"x"}],"n":{"type":"integer","value":"-3"}}`
	if got != want {
		t.Errorf("got %s\nwant %s", got, want)
	}
	if v := NewFloat(0.1).Text(); v != "1.0000000000000001e-01" {
		t.Errorf("NewFloat text = %s", v)
	}
}
