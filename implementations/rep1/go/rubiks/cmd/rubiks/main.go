// Command rubiks reads scrambles of a 3x3x3 Rubik's cube from standard
// input, one per line, and prints a solution for each on standard output.
//
// Each input line holds zero or more move tokens (U D L R F B, optionally
// followed by ' or 2) separated by single spaces. The output has one line per
// input line: moves that return the scrambled cube to the solved state.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"

	"example.com/rubiks/cube"
	"example.com/rubiks/solver"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "rubiks:", err)
		os.Exit(1)
	}
}

func run(in io.Reader, out io.Writer) error {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 1<<16), 1<<26)
	w := bufio.NewWriterSize(out, 1<<16)

	var s *solver.Solver // built on the first non-trivial scramble
	var buf []byte
	line := 0
	for sc.Scan() {
		line++
		scramble, err := cube.ParseMoves(sc.Text())
		if err != nil {
			return fmt.Errorf("line %d: %w", line, err)
		}
		c := cube.Solved()
		c.ApplyAll(scramble)
		buf = buf[:0]
		if !c.IsSolved() {
			if s == nil {
				s = solver.New()
			}
			sol, err := s.Solve(c)
			if err != nil {
				return fmt.Errorf("line %d: %w", line, err)
			}
			buf = cube.AppendMoves(buf, sol)
		}
		buf = append(buf, '\n')
		if _, err := w.Write(buf); err != nil {
			return err
		}
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return w.Flush()
}
