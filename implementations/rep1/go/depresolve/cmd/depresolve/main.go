// Command depresolve reads a registry and root manifest on stdin and prints
// the resolution (or "unsatisfiable") on stdout.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"

	"example.com/depresolve"
)

func main() {
	reg, root, err := depresolve.Parse(bufio.NewReaderSize(os.Stdin, 1<<20))
	if err != nil {
		fmt.Fprintln(os.Stderr, "depresolve:", err)
		os.Exit(2)
	}
	res, err := reg.Resolve(root)
	out := bufio.NewWriter(os.Stdout)
	switch {
	case errors.Is(err, depresolve.ErrUnsatisfiable):
		out.WriteString("unsatisfiable\n")
	case err != nil:
		fmt.Fprintln(os.Stderr, "depresolve:", err)
		os.Exit(1)
	default:
		out.WriteString(res.Format())
	}
	if err := out.Flush(); err != nil {
		fmt.Fprintln(os.Stderr, "depresolve:", err)
		os.Exit(1)
	}
}
