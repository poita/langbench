// Command webhooks reads commands from standard input (sha256, hmac, b64enc,
// sign, verify, simulate, ...) and writes one result per command to standard
// output. See the README for the protocol.
package main

import (
	"bufio"
	"fmt"
	"os"

	"example.com/webhooks/commands"
)

func main() {
	w := bufio.NewWriterSize(os.Stdout, 1<<16)
	err := commands.Run(os.Stdin, w)
	if err == nil {
		err = w.Flush()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "webhooks:", err)
	}
	// The protocol defines the exit status as always 0.
}
