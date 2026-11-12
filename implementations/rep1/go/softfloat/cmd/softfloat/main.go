// Command softfloat reads binary32 operations from standard input, one per
// line ("add a b", "sub a b", "mul a b", "div a b", "sqrt a", operands as 8
// hex digits), and prints each result as 8 hex digits on its own line.
package main

import (
	"fmt"
	"os"

	"softfloat/batch"
)

func main() {
	if err := batch.Run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "softfloat:", err)
		os.Exit(1)
	}
}
