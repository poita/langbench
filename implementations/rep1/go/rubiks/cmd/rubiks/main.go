// Command rubiks reads scrambles from standard input, one per line, and
// prints for each a move sequence that solves the cube.
//
// Each input line holds zero or more space-separated move tokens (U D L R F B,
// each optionally followed by ' or 2). The i-th output line is a solution to
// the cube obtained by applying the i-th scramble to a solved cube.
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"rubiks/cube"
	"rubiks/solver"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "rubiks:", err)
		os.Exit(1)
	}
}

// run solves every scramble read from in and writes the solutions to out.
func run(in io.Reader, out io.Writer) error {
	data, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	if len(data) == 0 {
		return nil
	}
	// A final newline terminates the last line rather than starting a new one.
	data = bytes.TrimSuffix(data, []byte("\n"))

	s := solver.New()
	var buf []byte
	lineNo := 0
	for _, line := range bytes.Split(data, []byte("\n")) {
		lineNo++
		moves, err := cube.ParseMoves(string(line))
		if err != nil {
			return fmt.Errorf("line %d: %w", lineNo, err)
		}
		sol, err := s.Solve(cube.Scrambled(moves))
		if err != nil {
			return fmt.Errorf("line %d: %w", lineNo, err)
		}
		buf = cube.AppendMoves(buf, sol)
		buf = append(buf, '\n')
	}
	_, err = out.Write(buf)
	return err
}
