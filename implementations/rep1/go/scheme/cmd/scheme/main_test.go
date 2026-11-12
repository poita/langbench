package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestCLI(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "scheme")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	cmd := exec.Command(bin)
	cmd.Stdin = strings.NewReader("(display \"a\")\n(+ 1 2)\n(car '())\n(display \"never\")")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	if want := "a3\nerror: type-error\n"; string(out) != want {
		t.Errorf("got %q, want %q", out, want)
	}
}
