package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestMain lets the test binary double as the CLI when BIGINT_CLI=1.
func TestMain(m *testing.M) {
	if os.Getenv("BIGINT_CLI") == "1" {
		main()
		return
	}
	os.Exit(m.Run())
}

func TestCLI(t *testing.T) {
	cmd := exec.Command(os.Args[0])
	cmd.Env = append(os.Environ(), "BIGINT_CLI=1")
	cmd.Stdin = strings.NewReader("12 + 30\n1 / 0\n2 ^ 64")
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	if want := "42\nerror\n18446744073709551616\n"; string(out) != want {
		t.Errorf("got %q, want %q", out, want)
	}
}
