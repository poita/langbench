// Command textbuffer reads a document and a list of editing commands from
// standard input and writes the result of every print command to standard
// output. See the README for the input format.
package main

import (
	"fmt"
	"os"

	"textbuffer/internal/script"
)

func main() {
	if err := script.Run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "textbuffer:", err)
		os.Exit(1)
	}
}
