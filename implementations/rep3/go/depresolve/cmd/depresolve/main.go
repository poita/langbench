// Command depresolve reads a package registry and a root manifest from
// standard input and prints the resolution defined by the depresolve library
// (one "name version" line per chosen package, sorted by name), or the single
// line "unsatisfiable" when none exists.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"

	"github.com/example/depresolve"
)

func main() {
	os.Exit(run())
}

func run() int {
	p, err := depresolve.ParseReader(bufio.NewReaderSize(os.Stdin, 1<<20))
	if err != nil {
		fmt.Fprintln(os.Stderr, "depresolve:", err)
		return 2
	}
	res, err := p.Resolve()
	switch {
	case errors.Is(err, depresolve.ErrUnsatisfiable):
		fmt.Print("unsatisfiable\n")
	case err != nil:
		fmt.Fprintln(os.Stderr, "depresolve:", err)
		return 1
	default:
		if _, err := res.WriteTo(os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "depresolve:", err)
			return 1
		}
	}
	return 0
}
