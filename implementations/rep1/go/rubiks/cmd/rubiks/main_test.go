package main

import (
	"bytes"
	"strings"
	"testing"

	"rubiks/cube"
)

func solveText(t *testing.T, in string) []string {
	t.Helper()
	var out bytes.Buffer
	if err := run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	s := out.String()
	if s != "" && !strings.HasSuffix(s, "\n") {
		t.Fatalf("output %q lacks final newline", s)
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n")
}

func TestLineHandling(t *testing.T) {
	tests := []struct {
		in    string
		lines int
	}{
		{"R", 1},
		{"R\n", 1},
		{"R\n\n", 2},
		{"\n", 1},
		{"F R U'\n\nR U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'", 3},
	}
	for _, tc := range tests {
		if got := solveText(t, tc.in); len(got) != tc.lines {
			t.Errorf("input %q: %d output lines, want %d", tc.in, len(got), tc.lines)
		}
	}
}

func TestSolutionsAreCorrect(t *testing.T) {
	scrambles := []string{"", "R", "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2", "F R U'"}
	got := solveText(t, strings.Join(scrambles, "\n")+"\n")
	if len(got) != len(scrambles) {
		t.Fatalf("got %d lines", len(got))
	}
	for i, s := range scrambles {
		moves, _ := cube.ParseMoves(s)
		sol, err := cube.ParseMoves(got[i])
		if err != nil {
			t.Fatal(err)
		}
		c := cube.Scrambled(moves)
		c.ApplyAll(sol)
		if !c.IsSolved() || len(sol) > 52 {
			t.Errorf("line %d: bad solution %q", i, got[i])
		}
	}
	if got[0] != "" {
		t.Errorf("empty scramble should give empty line, got %q", got[0])
	}
}

func TestInvalidToken(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader("R X\n"), &out); err == nil {
		t.Error("expected an error for invalid token")
	}
}

func TestEmptyInput(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader(""), &out); err != nil || out.Len() != 0 {
		t.Errorf("empty input: err=%v out=%q", err, out.String())
	}
}
