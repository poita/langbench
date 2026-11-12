// Command webhooks reads commands from stdin and writes results to stdout.
// See the README for the command language. The exit status is 0 unless
// stdin or stdout fail at the I/O level.
package main

import (
	"fmt"
	"os"

	"example.com/webhooks/protocol"
)

func main() {
	if err := protocol.Run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "webhooks:", err)
		os.Exit(1)
	}
}
