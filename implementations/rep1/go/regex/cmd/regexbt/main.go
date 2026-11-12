// Command regexbt reads patterns and subjects in the batch format described
// in the README from standard input and prints the first match of each
// pattern in each subject, with capture group positions.
package main

import (
	"fmt"
	"os"

	"example.com/regexbt/internal/batch"
)

func main() {
	if err := batch.Run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "regexbt:", err)
		os.Exit(1)
	}
}
