package main

import (
	"bytes"
	"strings"
	"testing"

	"example.com/rubiks/cube"
)

func TestRun(t *testing.T) {
	in := "F R U'\n\nR U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'\n" +
		"U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2"
	var out bytes.Buffer
	if err := run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	solutions := strings.Split(out.String(), "\n")
	scrambles := strings.Split(in, "\n")
	if len(solutions) != len(scrambles)+1 || solutions[len(solutions)-1] != "" {
		t.Fatalf("got %d output lines for %d scrambles: %q", len(solutions), len(scrambles), out.String())
	}
	for i, scr := range scrambles {
		sc, _ := cube.ParseMoves(scr)
		sol, err := cube.ParseMoves(solutions[i])
		if err != nil {
			t.Fatal(err)
		}
		if len(sol) > 52 {
			t.Errorf("line %d: %d moves", i, len(sol))
		}
		c := cube.Solved()
		c.ApplyAll(sc)
		c.ApplyAll(sol)
		if !c.IsSolved() {
			t.Errorf("line %d: not solved", i)
		}
	}
	if solutions[1] != "" {
		t.Errorf("empty scramble should give an empty line, got %q", solutions[1])
	}
}

func TestRunLineCounts(t *testing.T) {
	for in, want := range map[string]string{
		"\n":     "\n",
		"R\n\n":  "R'\n\n",
		"R":      "R'\n",
		"R\nR\n": "R'\nR'\n",
	} {
		var out bytes.Buffer
		if err := run(strings.NewReader(in), &out); err != nil {
			t.Fatal(err)
		}
		lines := strings.Count(out.String(), "\n")
		if wantLines := strings.Count(want, "\n"); lines != wantLines {
			t.Errorf("input %q: %d output lines, want %d", in, lines, wantLines)
		}
	}
}

func TestRunInvalidToken(t *testing.T) {
	if err := run(strings.NewReader("R Q\n"), &bytes.Buffer{}); err == nil {
		t.Error("invalid token accepted")
	}
}
