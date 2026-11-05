// Command sat reads a DIMACS CNF formula on standard input and prints
// "UNSAT", or "SAT" followed by a satisfying assignment line.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/example/sat/dimacs"
	"github.com/example/sat/solver"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "sat:", err)
		os.Exit(1)
	}
}

func run(in io.Reader, out io.Writer) error {
	data, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	f, err := dimacs.Parse(data)
	if err != nil {
		return err
	}
	s := solver.New(f.NumVars)
	for _, c := range f.Clauses {
		if !s.AddClause(c...) {
			break
		}
	}
	if s.Solve() == solver.Unsat {
		return dimacs.WriteResult(out, false, nil)
	}
	return dimacs.WriteResult(out, true, s.Model())
}
