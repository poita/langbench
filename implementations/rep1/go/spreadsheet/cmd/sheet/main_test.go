package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	tests := []struct {
		name, in, want string
	}{
		{"empty", "", ""},
		{"example 1", "set A1 10\nset A2 32\nset A3 =A1+A2\nget A3\nset A1 =A3\nget A1\nget A3\nset A1 5\nget A3\ndump",
			"42\n#CYCLE!\n#CYCLE!\n37\nA1 5\nA2 32\nA3 37\n"},
		{"strings and clear", "set A1 \"Total\"\nset B1 \"\"\nget B1\nclear A1\nget A1\ndump\n",
			"\n\nB1 \n"},
		{"string with spaces", "set A1 \"  a  b \"\nget A1\n", "  a  b \n"},
		{"no output without get", "set A1 1\nclear A1\n", ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			if err := run(strings.NewReader(tc.in), &out); err != nil {
				t.Fatal(err)
			}
			if out.String() != tc.want {
				t.Errorf("output %q, want %q", out.String(), tc.want)
			}
		})
	}
}

func TestRunReportsBadCommands(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader("frobnicate A1\nget A1\n"), &out); err == nil {
		t.Error("expected error for unknown command")
	}
	if out.String() != "\n" {
		t.Errorf("processing should continue, got %q", out.String())
	}
}
