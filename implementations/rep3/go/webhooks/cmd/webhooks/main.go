// Command webhooks reads a command stream on stdin and writes the results to
// stdout. See the README for the command language.
package main

import (
	"io"
	"os"

	"webhooks/internal/cli"
)

func main() {
	input, _ := io.ReadAll(os.Stdin)
	os.Stdout.Write(cli.Run(input))
}
