package hyphen

import (
	"os"
	"reflect"
	"testing"
)

func load(t *testing.T) *Patterns {
	t.Helper()
	f, err := os.Open("../data/hyphen/english.chp")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	p, err := Parse(f)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestPatternParsing(t *testing.T) {
	key, vals := parsePattern(".anti3")
	if key != ".anti" || !reflect.DeepEqual(vals, []uint8{0, 0, 0, 0, 0, 3}) {
		t.Errorf("got %q %v", key, vals)
	}
	key, vals = parsePattern("c2h")
	if key != "ch" || !reflect.DeepEqual(vals, []uint8{0, 2, 0}) {
		t.Errorf("got %q %v", key, vals)
	}
	key, vals = parsePattern("3tion")
	if key != "tion" || !reflect.DeepEqual(vals, []uint8{3, 0, 0, 0, 0}) {
		t.Errorf("got %q %v", key, vals)
	}
}

func TestPoints(t *testing.T) {
	p := load(t)
	cases := map[string][]int{
		"winter":       {3},
		"typesetting":  {7, 8},
		"national":     {2, 4},
		"introduction": {2, 8},
		"algorithm":    {2, 4}, // exception al-go-rithm
		"a":            nil,
	}
	for w, want := range cases {
		if got := p.Points(w); !reflect.DeepEqual(got, want) {
			t.Errorf("Points(%q) = %v, want %v", w, got, want)
		}
	}
}
