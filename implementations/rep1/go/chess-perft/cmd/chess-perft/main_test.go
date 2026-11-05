package main

import (
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	in := strings.Join([]string{
		"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 1",
		"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3",
		"r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1 0",
		"8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1",
		"7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3",
	}, "\n") // no trailing newline
	want := "20\n8902\n1\n" +
		"a6a5 1\na6b5 1\na7a8b 1\na7a8n 1\na7a8q 1\na7a8r 1\ntotal 6\n" +
		"total 0\n"
	var out strings.Builder
	if err := run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != want {
		t.Errorf("got:\n%s\nwant:\n%s", out.String(), want)
	}
}

func TestRunEmptyInput(t *testing.T) {
	var out strings.Builder
	if err := run(strings.NewReader(""), &out); err != nil || out.Len() != 0 {
		t.Errorf("err=%v out=%q", err, out.String())
	}
}

func TestRunTrailingNewline(t *testing.T) {
	var out strings.Builder
	in := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 2\n"
	if err := run(strings.NewReader(in), &out); err != nil || out.String() != "400\n" {
		t.Errorf("err=%v out=%q", err, out.String())
	}
}

func TestRunMalformed(t *testing.T) {
	for _, in := range []string{
		"8/8/8/8/8/8/8/K6k w - - 0 1\n",
		"8/8/8/8/8/8/8/K6k w - - 0 1 x\n",
		"8/8/8/8/8/8/8/K6k w - - 0 1 split 2\n",
		"not a fen at all really no 3\n",
	} {
		var out strings.Builder
		if err := run(strings.NewReader(in), &out); err == nil {
			t.Errorf("run(%q) succeeded, want error", in)
		}
	}
}
