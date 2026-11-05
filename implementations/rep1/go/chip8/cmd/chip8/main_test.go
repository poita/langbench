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
	lines := strings.Split(out.String(), "\n")
	if len(lines) != 35 || lines[32] != "PC=0208 I=0000 SP=0 DT=00 ST=00" {
		t.Errorf("unexpected output:\n%s", out.String())
	}
}

func TestRunMalformed(t *testing.T) {
	if err := run(strings.NewReader("zz\n1\n"), &bytes.Buffer{}); err == nil {
		t.Error("expected error")
	}
}
