// Command depresolve reads a package registry and a root manifest on standard
// input and prints the resolved package versions, one "name version" per line
// sorted by name, or "unsatisfiable" when no resolution exists.
package main

import (
	"bufio"
	"fmt"
	"os"

	"depresolve"
)

func main() {
	out := bufio.NewWriter(os.Stdout)
	err := depresolve.Run(bufio.NewReaderSize(os.Stdin, 1<<20), out)
	if ferr := out.Flush(); err == nil {
		err = ferr
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "depresolve:", err)
		os.Exit(1)
	}
}
