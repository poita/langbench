package main

import (
	"bytes"
	"strings"
	"testing"
)

func runCLI(input string) string {
	var out bytes.Buffer
	run(strings.NewReader(input), &out)
	return out.String()
}

func TestCLI(t *testing.T) {
	tests := []struct{ in, want string }{
		{".a\n{\"a\": 1}\n", "1\n"},
		{".[]\n[1,\n2]", "1\n2\n"},
		{"empty\n1", ""},
		{".[] | .a\n[{\"a\":1},3,{\"a\":2}]", "1\nerror\n"},
		{"[(1,2) + (10,20)]\nnull", "[11,12,21,22]\n"},
	}
	for _, tc := range tests {
		if got := runCLI(tc.in); got != tc.want {
			t.Errorf("input %q: got %q want %q", tc.in, got, tc.want)
		}
	}
}
