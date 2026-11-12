package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestGolden runs every testdata/*.in through the command and compares its
// output with the matching .out file.
func TestGolden(t *testing.T) {
	inputs, err := filepath.Glob("testdata/*.in")
	if err != nil || len(inputs) == 0 {
		t.Fatalf("no golden inputs found (%v)", err)
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
				t.Fatalf("exit status %d: %s", code, stderr.String())
			}
			if got := strings.TrimRight(stdout.String(), "\n"); got != strings.TrimRight(string(want), "\n") {
				t.Errorf("output mismatch\ngot:\n%s\nwant:\n%s", got, want)
			}
		})
	}
}

func TestOutputFormat(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run(strings.NewReader(`{"schema":{"type":"integer"},"tests":[{"description":"a","data":1},{"data":"x"}],"extra":true}`), &stdout, &stderr)
	if code != 0 || stdout.String() != "valid\ninvalid\n" || stderr.Len() != 0 {
		t.Errorf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestEmptyTests(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := run(strings.NewReader(`{"schema":true,"tests":[]}`), &stdout, &stderr); code != 0 || stdout.Len() != 0 {
		t.Errorf("code=%d stdout=%q", code, stdout.String())
	}
}

func TestRemotes(t *testing.T) {
	in := `{"schema":{"$ref":"http://r.test/s"},"remotes":{"http://r.test/s":{"type":"string"}},"tests":[{"data":"a"},{"data":1}]}`
	var stdout, stderr bytes.Buffer
	if code := run(strings.NewReader(in), &stdout, &stderr); code != 0 || stdout.String() != "valid\ninvalid\n" {
		t.Errorf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestMalformedInput(t *testing.T) {
	for _, in := range []string{
		``, `[`, `[]`, `{}`, `{"schema":true}`, `{"tests":[]}`, `{"schema":true,"tests":{}}`,
		`{"schema":true,"tests":[1]}`, `{"schema":true,"tests":[{}]}`,
		`{"schema":true,"tests":[],"remotes":[]}`, `{"schema":{"pattern":"("},"tests":[]}`,
	} {
		var stdout, stderr bytes.Buffer
		if code := run(strings.NewReader(in), &stdout, &stderr); code != 1 || stderr.Len() == 0 || stdout.Len() != 0 {
			t.Errorf("input %q: code=%d stdout=%q stderr=%q", in, code, stdout.String(), stderr.String())
		}
	}
}
