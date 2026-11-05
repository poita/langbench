package main

import (
	"strings"
	"testing"
)

func TestProcess(t *testing.T) {
	out, err := process([]byte("L auto 01234567\nH 5 héllo"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	if !strings.HasPrefix(s, "version 1 mask 3\n#######.##..#.#######\n") {
		t.Errorf("unexpected output start: %q", s[:40])
	}
	if strings.Count(s, "version 1 mask") != 2 || !strings.HasSuffix(s, "\n\n") {
		t.Error("expected two symbols each followed by a blank line")
	}
}

func TestProcessErrors(t *testing.T) {
	for _, in := range []string{"L auto", "X 0 hi", "L 9 hi", "L auto " + strings.Repeat("a", 3000)} {
		if _, err := process([]byte(in)); err == nil {
			t.Errorf("%.20q: expected error", in)
		}
	}
}
