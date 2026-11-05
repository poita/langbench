// Command sat reads a DIMACS CNF formula on standard input and prints
// "SAT" followed by a model line, or "UNSAT".
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/example/sat"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "sat:", err)
		os.Exit(1)
	}
}

func run(in io.Reader, out io.Writer) error {
	cnf, err := sat.ParseDIMACS(in)
	if err != nil {
		return err
	}
	st, model := sat.Solve(cnf)
	return sat.WriteResult(out, st, model)
}
