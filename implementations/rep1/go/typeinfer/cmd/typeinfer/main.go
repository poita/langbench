// Command typeinfer reads a program from standard input and prints the
// principal type of every top-level declaration, or an error line for each
// declaration that does not type-check. See the project README.
package main

import (
	"bufio"
	"fmt"
	"os"

	"github.com/example/typeinfer"
)

func main() {
	out := bufio.NewWriterSize(os.Stdout, 1<<16)
	err := typeinfer.Run(os.Stdin, out)
	if ferr := out.Flush(); err == nil {
		err = ferr
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "typeinfer:", err)
		os.Exit(1)
	}
}
