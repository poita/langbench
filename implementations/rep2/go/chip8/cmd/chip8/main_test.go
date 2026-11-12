package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader("60ff7001610180141208\n6\n"), &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n")
	if len(lines) != 34 {
		t.Fatalf("got %d lines, want 34", len(lines))
	}
	if lines[32] != "PC=0208 I=0000 SP=0 DT=00 ST=00" {
		t.Errorf("line 33 = %q", lines[32])
	}
	if lines[33] != "V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00" {
		t.Errorf("line 34 = %q", lines[33])
	}
}

func TestRunBadInput(t *testing.T) {
	if err := run(strings.NewReader("nothex\n1\n"), &bytes.Buffer{}); err == nil {
		t.Fatal("expected error")
	}
}
