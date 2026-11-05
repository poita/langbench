// Command diff reads a diff or patch request on standard input and writes the
// result to standard output. See the README for the format.
package main

import (
	"fmt"
	"io"
	"os"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "diff:", err)
		os.Exit(1)
	}
	out, err := Run(input)
	if err != nil {
		fmt.Fprintln(os.Stderr, "diff:", err)
		os.Exit(1)
	}
	if _, err := os.Stdout.Write(out); err != nil {
		fmt.Fprintln(os.Stderr, "diff:", err)
		os.Exit(1)
	}
}
