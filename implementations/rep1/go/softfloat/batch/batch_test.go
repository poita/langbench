package batch

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	in := "add 3f800000 3f800000\nsub 3f800000 3f800000\nmul 40400000 c0400000\ndiv 3f800000 40400000\nsqrt 40000000"
	want := "40000000\n00000000\nc1100000\n3eaaaaab\n3fb504f3\n"
	var out bytes.Buffer
	if err := Run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != want {
		t.Errorf("got %q, want %q", out.String(), want)
	}
}

func TestErrors(t *testing.T) {
	for _, line := range []string{"", "pow 3f800000 3f800000", "add 3f800000", "sqrt 3f800000 3f800000", "add 3f80000 3f800000", "add 3f80000g 3f800000"} {
		if _, err := EvalLine(line); err == nil {
			t.Errorf("EvalLine(%q): expected error", line)
		}
	}
}

func TestHexRoundTrip(t *testing.T) {
	for _, x := range []uint32{0, 1, 0x7fc00000, 0xdeadbeef, 0xffffffff} {
		got, err := ParseHex(FormatHex(x))
		if err != nil || got != x {
			t.Errorf("round trip %08x: %08x, %v", x, got, err)
		}
	}
}
