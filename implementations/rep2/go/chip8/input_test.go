package chip8

import "testing"

func TestParseInput(t *testing.T) {
	p, err := ParseInput([]byte("60ff\n12\n3:0001 9:ffff\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(p.ROM) != 2 || p.ROM[0] != 0x60 || p.Cycles != 12 || len(p.Schedule) != 2 ||
		p.Schedule[1] != (KeyEvent{9, 0xffff}) {
		t.Errorf("bad parse: %+v", p)
	}
}

func TestParseInputNoScheduleNoTrailingNewline(t *testing.T) {
	for _, in := range []string{"6001\n5", "6001\n5\n", "6001\n5\n\n"} {
		p, err := ParseInput([]byte(in))
		if err != nil || p.Cycles != 5 || len(p.Schedule) != 0 {
			t.Errorf("%q: %+v %v", in, p, err)
		}
	}
}

func TestParseErrors(t *testing.T) {
	for _, in := range []string{"", "6001", "600\n1", "zz\n1", "6001\nx", "6001\n1\n5:00", "6001\n9\n3:0001 3:0002"} {
		if _, err := ParseInput([]byte(in)); err == nil {
			t.Errorf("%q: expected error", in)
		}
	}
}

func TestLoadROMTooLarge(t *testing.T) {
	if err := New().LoadROM(make([]byte, MaxROMSize+1)); err == nil {
		t.Error("expected error")
	}
}
