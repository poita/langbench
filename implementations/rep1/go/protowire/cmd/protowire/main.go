// Command protowire reads a message schema and a list of decode/encode
// requests from standard input and prints one result line per request.
//
// Input is the schema, a line consisting of "--", then one request per line:
//
//	decode <Message> <hex>
//	encode <Message> <text form>
//
// A malformed request prints "error". See the README for details.
package main

import (
	"fmt"
	"io"
	"os"

	"example.com/protowire/internal/batch"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "protowire:", err)
		os.Exit(1)
	}
	if err := batch.Run(in, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "protowire:", err)
		os.Exit(1)
	}
}
