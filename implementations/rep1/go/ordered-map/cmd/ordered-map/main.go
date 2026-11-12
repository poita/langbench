// Command ordered-map reads a command script from stdin and prints one
// result line per command to stdout. See the README for the protocol.
package main

import (
	"fmt"
	"os"

	"example.com/orderedmap/internal/cli"
)

func main() {
	if err := cli.Run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "ordered-map:", err)
		os.Exit(1)
	}
}
