package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// normalize mirrors the conformance runner: trailing whitespace on each line
// and trailing newlines are ignored.
func normalize(s string) string {
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t\r\f\v")
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

// TestGolden runs every testdata/NAME.in through the command and compares
// stdout with testdata/NAME.out.
func TestGolden(t *testing.T) {
	inputs, err := filepath.Glob("testdata/*.in")
	if err != nil || len(inputs) == 0 {
		t.Fatalf("no golden inputs found (err=%v)", err)
	}
	for _, in := range inputs {
		name := strings.TrimSuffix(filepath.Base(in), ".in")
		t.Run(name, func(t *testing.T) {
			input, err := os.ReadFile(in)
			if err != nil {
				t.Fatal(err)
			}
			want, err := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
			if err != nil {
				t.Fatal(err)
			}
			var stdout, stderr bytes.Buffer
			if code := run(bytes.NewReader(input), &stdout, &stderr); code != 0 {
				t.Fatalf("exit code %d, stderr: %s", code, stderr.String())
			}
			if got := normalize(stdout.String()); got != normalize(string(want)) {
				t.Errorf("output mismatch\n got: %q\nwant: %q", got, normalize(string(want)))
			}
		})
	}
}

func TestRunErrors(t *testing.T) {
	tests := []struct {
		name, input, stdout string
		code                int
	}{
		{"success", "{\"n\": 2}\n--\n=== main\nn={{ n }}", "n=2\n", 0},
		{"template error", "{}\n--\n=== main\n{{ x }}", "error: undefined\n", 0},
		{"missing separator", "{}\n=== main\nhi", "", 2},
		{"bad json", "{\n--\n=== main\nhi", "", 2},
		{"no templates", "{}\n--\n", "", 2},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			code := run(strings.NewReader(tc.input), &stdout, &stderr)
			if code != tc.code || stdout.String() != tc.stdout {
				t.Errorf("got code %d stdout %q, want code %d stdout %q", code, stdout.String(), tc.code, tc.stdout)
			}
		})
	}
}
