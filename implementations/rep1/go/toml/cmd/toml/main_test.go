package main

import "testing"

func TestRun(t *testing.T) {
	tests := []struct{ in, want string }{
		{"decode\na = 1\n", `{"a":{"type":"integer","value":"1"}}` + "\n"},
		{"decode\n", "{}\n"},
		{"decode\na = \n", "error\n"},
		{"decode\n\xff", "error\n"},
		{"encode\n{\"a\":{\"type\":\"integer\",\"value\":\"1\"}}", "a = 1\n"},
		{"encode\n{}\n", "\n"},
	}
	for _, tc := range tests {
		if got := string(run([]byte(tc.in))); got != tc.want {
			t.Errorf("run(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
