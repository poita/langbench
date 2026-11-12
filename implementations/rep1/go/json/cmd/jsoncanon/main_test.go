package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	tests := []struct{ in, want string }{
		{`{ "b": 1, "a": 1E2 }`, "{\"a\":1e2,\"b\":1}\n"},
		{`[1,]`, "invalid\n"},
		{``, "invalid\n"},
		{"\xff", "invalid\n"},
	}
	for _, tc := range tests {
		var out bytes.Buffer
		if code := run(strings.NewReader(tc.in), &out); code != 0 {
			t.Errorf("run(%q) exit %d", tc.in, code)
		}
		if out.String() != tc.want {
			t.Errorf("run(%q) = %q, want %q", tc.in, out.String(), tc.want)
		}
	}
}
