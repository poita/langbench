// Command bigint evaluates arbitrary-precision integer queries.
//
// It reads one query per line from standard input, in the form "<a> <op> <b>"
// with op one of + - * / % ^ cmp, and prints one result line per query to
// standard output ("error" for division by zero or a negative exponent).
package main

import (
	"fmt"
	"os"

	"example.com/bigint/internal/query"
)

func main() {
	if err := query.Run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "bigint:", err)
		os.Exit(1)
	}
}
