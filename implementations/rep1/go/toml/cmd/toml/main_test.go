package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"decode", "decode\na = 1\n", `{"a":{"type":"integer","value":"1"}}` + "\n"},
		{"decode empty", "decode\n", "{}\n"},
		{"decode error", "decode\na =\n", "error\n"},
		{"encode", "encode\n{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}", "a = 1\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			if code := run(strings.NewReader(tc.in), &out); code != 0 {
				t.Fatalf("exit code %d", code)
			}
			if out.String() != tc.want {
				t.Errorf("got %q want %q", out.String(), tc.want)
			}
		})
	}
}
