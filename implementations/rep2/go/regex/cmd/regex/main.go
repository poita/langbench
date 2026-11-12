// Command regex reads patterns and subjects from standard input and prints,
// for each subject, the first match and its capture groups. See the batch
// package for the input and output format.
package main

import (
	"fmt"
	"os"

	"example.com/regex/internal/batch"
)

func main() {
	if err := batch.Run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "regex:", err)
		os.Exit(1)
	}
}
