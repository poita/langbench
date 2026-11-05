// Command protowire reads a schema and a list of decode/encode requests from
// standard input and writes one result line per request to standard output.
//
//	protowire < requests.txt
//
// See the project README for the input format.
package main

import (
	"fmt"
	"io"
	"os"

	"protowire/batch"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "protowire: reading stdin:", err)
		os.Exit(1)
	}
	out, err := batch.Run(input)
	if err != nil {
		fmt.Fprintln(os.Stderr, "protowire:", err)
		os.Exit(1)
	}
	if _, err := os.Stdout.Write(out); err != nil {
		fmt.Fprintln(os.Stderr, "protowire: writing stdout:", err)
		os.Exit(1)
	}
}
