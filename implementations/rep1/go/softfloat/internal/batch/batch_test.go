package batch

import (
	"strings"
	"testing"

	"softfloat"
)

func TestProcess(t *testing.T) {
	in := "add 3f800000 3f800000\nsub 3f800000 3f800000\nmul 40400000 c0400000\n" +
		"div 3f800000 40400000\nsqrt 40000000"
	want := "40000000\n00000000\nc1100000\n3eaaaaab\n3fb504f3\n"
	got, err := Process([]byte(in))
	if err != nil || string(got) != want {
		t.Fatalf("got %q, %v; want %q", got, err, want)
	}
}

func TestProcessCRLFAndTrailingNewline(t *testing.T) {
	got, err := Process([]byte("add 3f800000 3f800000\r\nsqrt 40000000\n"))
	if err != nil || string(got) != "40000000\n3fb504f3\n" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestParseLine(t *testing.T) {
	op, a, b, err := ParseLine([]byte("div 7f800000 0000000a"))
	if err != nil || op != softfloat.OpDiv || a != 0x7f800000 || b != 0xa {
		t.Fatalf("got %v %x %x %v", op, a, b, err)
	}
	bad := []string{"", "add", "add 3f800000", "add 3f800000 3f80000", "add 3f800000 3f80000g",
		"sqrt 3f800000 3f800000", "pow 3f800000 3f800000", "sqrt3f800000", "add 3f800000  3f800000"}
	for _, s := range bad {
		if _, _, _, err := ParseLine([]byte(s)); err == nil {
			t.Errorf("ParseLine(%q) succeeded", s)
		}
	}
}

func TestProcessError(t *testing.T) {
	out, err := Process([]byte("sqrt 40000000\nbogus\n"))
	if err == nil || !strings.Contains(err.Error(), "line 2") || string(out) != "3fb504f3\n" {
		t.Fatalf("got %q, %v", out, err)
	}
}

func TestAppendHex8(t *testing.T) {
	if got := string(AppendHex8(nil, 0x0000abcd)); got != "0000abcd\n" {
		t.Fatalf("got %q", got)
	}
}
