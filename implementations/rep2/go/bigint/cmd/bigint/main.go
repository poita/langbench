// Command bigint evaluates arbitrary-precision integer queries.
//
// It reads queries of the form "<a> <op> <b>" from standard input, one per
// line, and writes one result line per query to standard output. See the
// README for the full format.
package main

import (
	"fmt"
	"io"
	"os"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bigint:", err)
		os.Exit(1)
	}
	if _, err := os.Stdout.Write(Process(in)); err != nil {
		fmt.Fprintln(os.Stderr, "bigint:", err)
		os.Exit(1)
	}
}
