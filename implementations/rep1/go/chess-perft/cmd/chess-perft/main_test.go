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
		{"empty input", "", ""},
		{"perft queries", `rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 1
rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3
r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1 0`,
			"20\n8902\n1\n"},
		{"divide with promotions", "8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1\n",
			"a6a5 1\na6b5 1\na7a8b 1\na7a8n 1\na7a8q 1\na7a8r 1\ntotal 6\n"},
		{"divide of a stalemate", "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3\n", "total 0\n"},
		{"mixed, trailing newline", "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 2\n8/8/8/8/8/8/8/K6k w - - 0 1 divide 2\n",
			"0\na1a2 3\na1b1 3\na1b2 3\ntotal 9\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var out bytes.Buffer
			if err := run(strings.NewReader(tt.in), &out); err != nil {
				t.Fatal(err)
			}
			if out.String() != tt.want {
				t.Errorf("got %q, want %q", out.String(), tt.want)
			}
		})
	}
}

func TestRunMalformed(t *testing.T) {
	var out bytes.Buffer
	in := "8/8/8/8/8/8/8/K6k w - - 0 1 1\nnot a query\n"
	err := run(strings.NewReader(in), &out)
	if err == nil || !strings.Contains(err.Error(), "line 2") {
		t.Errorf("error = %v, want mention of line 2", err)
	}
	if out.String() != "3\n" {
		t.Errorf("results before the error were not written: %q", out.String())
	}
	for _, bad := range []string{
		"8/8/8/8/8/8/8/K6k w - - 0 1 x",
		"8/8/8/8/8/8/8/K6k w - - 0 1 divide 0",
		"8/8/8/8/8/8/8/K6k w - - 0 1 foo 2",
		"8/8/8/8/8/8/8/K6k w - - 0 1 -1",
	} {
		if _, err := parseQuery(bad); err == nil {
			t.Errorf("parseQuery(%q) succeeded", bad)
		}
	}
}
