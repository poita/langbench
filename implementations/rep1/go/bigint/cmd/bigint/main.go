// Command bigint evaluates arbitrary-precision integer queries.
//
// It reads queries of the form "<a> <op> <b>" from standard input, one per
// line, where op is one of + - * / % ^ cmp, and writes one result line per
// query to standard output. Division by zero and negative exponents print
// "error".
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/example/bigint/internal/queries"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bigint:", err)
		os.Exit(1)
	}
	out := queries.Process(in, make([]byte, 0, len(in)/2+64))
	if _, err := os.Stdout.Write(out); err != nil {
		fmt.Fprintln(os.Stderr, "bigint:", err)
		os.Exit(1)
	}
}
