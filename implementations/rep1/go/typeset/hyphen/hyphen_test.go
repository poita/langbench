package hyphen

import (
	"reflect"
	"testing"
)

const sample = `chp 1
left 2
right 3
pattern n1t
pattern t1t
pattern 3ing
pattern n1g
pattern .in3
pattern 3tion
pattern i1o
exception al-go-rithm
`

func TestPositions(t *testing.T) {
	s, err := Parse(sample)
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string][]int{
		"winter":      {3},
		"typesetting": {7, 8},
		"national":    {2, 4},
		"algorithm":   {2, 4},
		"abc":         nil,
	}
	for w, want := range cases {
		got := s.Positions(w)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("Positions(%q) = %v want %v", w, got, want)
		}
	}
}

func TestSplitPattern(t *testing.T) {
	k, v := splitPattern(".anti3")
	if k != ".anti" || !reflect.DeepEqual(v, []uint8{0, 0, 0, 0, 0, 3}) {
		t.Errorf(".anti3 -> %q %v", k, v)
	}
	k, v = splitPattern("c2h")
	if k != "ch" || !reflect.DeepEqual(v, []uint8{0, 2, 0}) {
		t.Errorf("c2h -> %q %v", k, v)
	}
	k, v = splitPattern("3tion")
	if k != "tion" || !reflect.DeepEqual(v, []uint8{3, 0, 0, 0, 0}) {
		t.Errorf("3tion -> %q %v", k, v)
	}
}
