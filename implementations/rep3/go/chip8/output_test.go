package chip8

import (
	"strings"
	"testing"
)

func TestRenderFormat(t *testing.T) {
	m := New()
	m.PC, m.I, m.SP, m.DT, m.ST = 0xabc, 0x0f, 16, 0x0a, 0xff
	m.V[15] = 0x0b
	m.Display.SetPixel(0, 0, true)
	m.Display.SetPixel(63, 31, true)
	out := string(m.Render())
	lines := strings.Split(out, "\n")
	if len(lines) != 35 || lines[34] != "" {
		t.Fatalf("got %d lines", len(lines))
	}
	if lines[0] != "#"+strings.Repeat(".", 63) || lines[31] != strings.Repeat(".", 63)+"#" {
		t.Error("display rows wrong")
	}
	if lines[32] != "PC=0abc I=000f SP=16 DT=0a ST=ff" {
		t.Errorf("%q", lines[32])
	}
	if lines[33] != "V=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 0b" {
		t.Errorf("%q", lines[33])
	}
}

func TestFontLoaded(t *testing.T) {
	m := New()
	if m.Mem[0x050] != 0xF0 || m.Mem[0x09F] != 0x80 || m.Mem[0x0A0] != 0 {
		t.Error("font not loaded correctly")
	}
}
