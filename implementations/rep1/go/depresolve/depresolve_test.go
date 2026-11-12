package depresolve_test

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	"depresolve"
)

func run(t *testing.T, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := depresolve.Run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

func TestRun(t *testing.T) {
	if got := run(t, "root:\n"); got != "" {
		t.Errorf("empty root printed %q", got)
	}
	if got := run(t, "a 1.0.0:\nroot: a *\n"); got != "a 1.0.0\n" {
		t.Errorf("got %q", got)
	}
	if got := run(t, "root: a *\n"); got != "unsatisfiable\n" {
		t.Errorf("got %q", got)
	}
}

func TestRunMalformed(t *testing.T) {
	var out bytes.Buffer
	if err := depresolve.Run(strings.NewReader("garbage\n"), &out); err == nil {
		t.Error("expected error for malformed input")
	}
}

func ExampleSolve() {
	res, err := depresolve.Solve(strings.NewReader(
		"a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n"))
	if err != nil {
		panic(err)
	}
	for _, p := range res {
		fmt.Println(p.Package, p.Version)
	}
	// Output:
	// a 1.0.0
	// b 1.0.0
	// c 1.2.5
}
