// Command sat reads a DIMACS CNF formula on standard input and prints
// "UNSAT", or "SAT" followed by a satisfying assignment, on standard output.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"

	"example.com/sat/dimacs"
)

func run(in io.Reader, out io.Writer) error {
	f, err := dimacs.Parse(in)
	if err != nil {
		return err
	}
	s := f.Solver()
	res := s.Solve()
	return dimacs.WriteResult(out, res, s.Model())
}

func main() {
	w := bufio.NewWriter(os.Stdout)
	err := run(bufio.NewReader(os.Stdin), w)
	if err == nil {
		err = w.Flush()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "sat:", err)
		os.Exit(1)
	}
}
