// Command sat reads a DIMACS CNF formula and prints SAT followed by a
// satisfying assignment, or UNSAT.
//
// Usage:
//
//	sat [file]
//
// With no argument the formula is read from standard input.
package main

import (
	"fmt"
	"io"
	"os"

	"example.com/sat/dimacs"
)

func main() {
	in := io.Reader(os.Stdin)
	if len(os.Args) > 1 {
		f, err := os.Open(os.Args[1])
		if err != nil {
			fmt.Fprintln(os.Stderr, "sat:", err)
			os.Exit(2)
		}
		defer f.Close()
		in = f
	}
	if err := run(in, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "sat:", err)
		os.Exit(1)
	}
}

// run solves the formula read from in and writes the verdict to out.
func run(in io.Reader, out io.Writer) error {
	cnf, err := dimacs.Parse(in)
	if err != nil {
		return err
	}
	s := cnf.Solver()
	st := s.Solve()
	return dimacs.WriteResult(out, st, s.Model())
}
