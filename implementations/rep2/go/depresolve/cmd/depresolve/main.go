// Command depresolve reads a package registry and a root manifest on standard
// input and prints the resolved versions, one "name version" line per
// package sorted by name, or the single line "unsatisfiable".
package main

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/example/depresolve"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout, os.Stderr))
}

func run(in io.Reader, out, errOut io.Writer) int {
	p, err := depresolve.Parse(in)
	if err != nil {
		fmt.Fprintln(errOut, "depresolve:", err)
		return 2
	}
	res, err := p.Resolve()
	switch {
	case errors.Is(err, depresolve.ErrUnsatisfiable):
		_, err = io.WriteString(out, "unsatisfiable\n")
	case err == nil:
		_, err = io.WriteString(out, res.String())
	}
	if err != nil {
		fmt.Fprintln(errOut, "depresolve:", err)
		return 1
	}
	return 0
}
