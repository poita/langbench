package main

import (
	"bytes"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestMain lets the test binary double as the CLI: when ORDERBOOK_CLI is set
// it runs main instead of the tests.
func TestMain(m *testing.M) {
	if os.Getenv("ORDERBOOK_CLI") == "1" {
		main()
		return
	}
	os.Exit(m.Run())
}

func runCLI(t *testing.T, stdin string, args ...string) (stdout string, code int) {
	t.Helper()
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(), "ORDERBOOK_CLI=1")
	cmd.Stdin = strings.NewReader(stdin)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		return out.String(), ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return out.String(), 0
}

func TestCLIExamples(t *testing.T) {
	for _, name := range []string{"example1", "example2", "example3"} {
		in, err := os.ReadFile("../../testdata/" + name + ".in")
		if err != nil {
			t.Fatal(err)
		}
		want, _ := os.ReadFile("../../testdata/" + name + ".out")
		got, code := runCLI(t, string(in))
		if code != 0 || got != string(want) {
			t.Errorf("%s: exit %d, output:\n%s", name, code, got)
		}
	}
}

func TestCLIEmpty(t *testing.T) {
	if got, code := runCLI(t, "0\n"); got != "" || code != 0 {
		t.Errorf("got %q, exit %d", got, code)
	}
}

func TestCLIFailures(t *testing.T) {
	if _, code := runCLI(t, "1\nBOGUS\n"); code != 1 {
		t.Errorf("malformed input: exit %d, want 1", code)
	}
	if _, code := runCLI(t, "0\n", "extra"); code != 2 {
		t.Errorf("extra argument: exit %d, want 2", code)
	}
}
