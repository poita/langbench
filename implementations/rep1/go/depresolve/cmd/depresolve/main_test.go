package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestCLI builds the command and checks its stdin/stdout contract.
func TestCLI(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "depresolve")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	cases := []struct{ in, want string }{
		{"root:\n", ""},
		{"b 1.0.0:\na 1.0.0: b *\nroot: a *\n", "a 1.0.0\nb 1.0.0\n"},
		{"root: x *\n", "unsatisfiable\n"},
	}
	for _, c := range cases {
		cmd := exec.Command(bin)
		cmd.Stdin = strings.NewReader(c.in)
		out, err := cmd.Output()
		if err != nil || string(out) != c.want {
			t.Errorf("input %q: got %q, %v; want %q", c.in, out, err, c.want)
		}
	}
	cmd := exec.Command(bin)
	cmd.Stdin = strings.NewReader("garbage\n")
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err == nil {
		t.Error("malformed input should exit nonzero")
	}
}
