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
	if !strings.HasSuffix(out.String(), "PC=0208 I=0000 SP=0 DT=00 ST=00\nV=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n") {
		t.Errorf("unexpected output:\n%s", out.String())
	}
}

func TestRunBadInput(t *testing.T) {
	if err := run(strings.NewReader("nope"), &bytes.Buffer{}); err == nil {
		t.Error("expected error")
	}
}
