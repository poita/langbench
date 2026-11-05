package chip8

import (
	"strings"
	"testing"
)

func TestFormatShape(t *testing.T) {
	m := New()
	m.I = 0xabcd
	m.SP = 16
	m.DT = 0x0f
	out := string(m.Format())
	lines := strings.Split(out, "\n")
	if len(lines) != 35 || lines[34] != "" {
		t.Fatalf("got %d lines", len(lines))
	}
	for _, l := range lines[:32] {
		if l != strings.Repeat(".", 64) {
			t.Fatalf("bad row %q", l)
		}
	}
	if lines[32] != "PC=0200 I=abcd SP=16 DT=0f ST=00" {
		t.Errorf("state line %q", lines[32])
	}
	if lines[33] != "V=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" {
		t.Errorf("V line %q", lines[33])
	}
}
