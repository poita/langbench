// Command diff reads a request on standard input and writes the answer to
// standard output.
//
// The first input line is the mode. In "diff" mode the input holds two
// counted blocks of lines, A and B, and the output is a minimal edit script
// from A to B. In "patch" mode it holds A and an edit script, and the output
// is the edited file. See the README for the exact format.
package main

import (
	"fmt"
	"os"

	"example.com/diff/internal/cli"
)

func main() {
	if err := cli.Run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "diff:", err)
		os.Exit(1)
	}
}
