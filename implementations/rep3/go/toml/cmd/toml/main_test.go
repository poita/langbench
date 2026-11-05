package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// buildTool compiles the command into a temp dir and returns its path.
func buildTool(t *testing.T) string {
	t.Helper()
	exe := filepath.Join(t.TempDir(), "toml")
	if out, err := exec.Command("go", "build", "-o", exe, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	return exe
}

func TestCLI(t *testing.T) {
	exe := buildTool(t)
	tests := []struct{ name, in, want string }{
		{"decode", "decode\na = 1\n", `{"a":{"type":"integer","value":"1"}}` + "\n"},
		{"decode empty", "decode\n", "{}\n"},
		{"decode error", "decode\na = \n", "error\n"},
		{"decode bom", "decode\n\xef\xbb\xbfa = 1\n", "error\n"},
		{"encode", "encode\n" + `{"a":{"type":"integer","value":"1"}}` + "\n", "a = 1\n"},
		{"encode empty", "encode\n{}", "\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cmd := exec.Command(exe)
			cmd.Stdin = bytes.NewReader([]byte(tc.in))
			var stdout bytes.Buffer
			cmd.Stdout = &stdout
			cmd.Stderr = os.Stderr
			if err := cmd.Run(); err != nil {
				t.Fatal(err)
			}
			if stdout.String() != tc.want {
				t.Errorf("got %q, want %q", stdout.String(), tc.want)
			}
		})
	}
}
