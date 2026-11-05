package chip8

import (
	"reflect"
	"testing"
)

func TestParseInput(t *testing.T) {
	in, err := ParseInputString("6001\n10\n0:0001 5:ffff")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(in.ROM, []byte{0x60, 0x01}) || in.Cycles != 10 {
		t.Errorf("%+v", in)
	}
	want := []KeyEvent{{0, 1}, {5, 0xffff}}
	if !reflect.DeepEqual(in.Events, want) {
		t.Errorf("events %v", in.Events)
	}
}

func TestParseInputOptionalParts(t *testing.T) {
	for _, s := range []string{"6001\n4000000000", "6001\n4000000000\n", "6001\n4000000000\n\n"} {
		in, err := ParseInputString(s)
		if err != nil {
			t.Fatalf("%q: %v", s, err)
		}
		if in.Cycles != 4000000000 || len(in.Events) != 0 {
			t.Errorf("%q: %+v", s, in)
		}
	}
}

func TestParseInputErrors(t *testing.T) {
	bad := []string{
		"", "6001", "600\n1", "zz\n1", "6001\nx", "6001\n4000000001",
		"6001\n1\n1:00", "6001\n1\n2:0000 1:0000", "6001\n1\n1:0000 1:0000",
	}
	for _, s := range bad {
		if _, err := ParseInputString(s); err == nil {
			t.Errorf("%q: expected error", s)
		}
	}
}
