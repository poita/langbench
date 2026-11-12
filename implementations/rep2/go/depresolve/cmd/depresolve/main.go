// Command depresolve reads a package registry and a root manifest from
// standard input and prints the resolved package versions, one
// "name version" per line sorted by name, or "unsatisfiable".
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/peteralexander/depresolve"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "depresolve:", err)
		os.Exit(1)
	}
}

func run(in io.Reader, w io.Writer) error {
	reg, root, err := depresolve.Parse(in)
	if err != nil {
		return err
	}
	out := bufio.NewWriter(w)
	sol, err := reg.Resolve(root)
	switch {
	case errors.Is(err, depresolve.ErrUnsatisfiable):
		out.WriteString("unsatisfiable\n")
	case err != nil:
		return err
	default:
		for _, p := range sol {
			out.WriteString(p.Name + " " + p.Version.String() + "\n")
		}
	}
	return out.Flush()
}
