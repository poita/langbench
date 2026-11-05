package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestCLI(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "depresolve")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	tests := []struct{ name, in, want string }{
		{"solution", "a 1.0.0: b ^1.0.0\nb 1.2.0:\nroot: a *\n", "a 1.0.0\nb 1.2.0\n"},
		{"unsat", "root: a *\n", "unsatisfiable\n"},
		{"empty", "root:\n", ""},
	}
	for _, tc := range tests {
		cmd := exec.Command(bin)
		cmd.Stdin = strings.NewReader(tc.in)
		out, err := cmd.Output()
		if err != nil || string(out) != tc.want {
			t.Errorf("%s: got %q, %v; want %q", tc.name, out, err, tc.want)
		}
	}
	cmd := exec.Command(bin)
	cmd.Stdin = strings.NewReader("garbage\n")
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err == nil {
		t.Error("malformed input should exit nonzero")
	}
}
