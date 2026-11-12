package main

import (
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty", "", ""},
		{"example1", "12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n", "42\n-2\n-3\n-1\n"},
		{"example2", "-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n",
			"0\n0\n0\n100000000000000000000\n1024\n1\n"},
		{"errors", "1 / 0\n0 % 0\n2 ^ -1\n5 / -0\n5 ^ -0\n", "error\nerror\nerror\nerror\n1\n"},
		{"no trailing newline", "3 cmp -2", "1\n"},
		{"cmp", "-3 cmp -2\n2 cmp 2\n", "-1\n0\n"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var out strings.Builder
			if err := run(strings.NewReader(tc.in), &out); err != nil {
				t.Fatal(err)
			}
			if out.String() != tc.want {
				t.Errorf("got %q, want %q", out.String(), tc.want)
			}
		})
	}
}
