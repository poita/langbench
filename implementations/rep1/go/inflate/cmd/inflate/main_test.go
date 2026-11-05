package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"empty data", "0300\n", "\n"},
		{"stored", "010100feff41\n", "41\n"},
		{"backref", "4b4c4a862000\n", "616263616263616263\n"},
		{"surrounding whitespace", "  4b4c4a862000 \r\n\n", "616263616263616263\n"},
		{"no newline", "010100feff41", "41\n"},
		{"empty input", "\n", "error\n"},
		{"empty input, no newline", "", "error\n"},
		{"bad distance", "030200\n", "error\n"},
		{"trailing data", "030000\n", "error\n"},
		{"bad hex", "zz\n", "error\n"},
	}
	for _, tc := range tests {
		var out bytes.Buffer
		if err := run(strings.NewReader(tc.in), &out); err != nil {
			t.Errorf("%s: %v", tc.name, err)
		}
		if out.String() != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, out.String(), tc.want)
		}
	}
}
