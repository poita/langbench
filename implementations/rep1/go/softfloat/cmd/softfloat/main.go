// Command softfloat reads binary32 operations from standard input, one per
// line ("add 3f800000 3f800000", "sqrt 40000000"), and prints the result bit
// pattern of each as eight lowercase hex digits.
package main

import (
	"fmt"
	"io"
	"os"

	"softfloat/internal/batch"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "softfloat: read:", err)
		os.Exit(1)
	}
	out, err := batch.Process(in)
	if _, werr := os.Stdout.Write(out); werr != nil {
		fmt.Fprintln(os.Stderr, "softfloat: write:", werr)
		os.Exit(1)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "softfloat:", err)
		os.Exit(1)
	}
}
