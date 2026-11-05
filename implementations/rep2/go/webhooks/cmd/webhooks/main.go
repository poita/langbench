// Command webhooks reads a command stream on stdin and writes the results to
// stdout; see the README for the command language.
package main

import (
	"io"
	"os"

	"example.com/webhooks/internal/protocol"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		os.Stderr.WriteString("webhooks: " + err.Error() + "\n")
	}
	os.Stdout.Write(protocol.Run(in))
}
