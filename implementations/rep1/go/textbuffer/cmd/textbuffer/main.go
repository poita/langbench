// Command textbuffer reads an initial document and a list of editing
// commands from standard input and prints the document and cursor positions
// for every print command. See the README for the command language.
package main

import (
	"fmt"
	"io"
	"os"

	"textbuffer/internal/script"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err == nil {
		err = script.Run(input, os.Stdout)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "textbuffer:", err)
		os.Exit(1)
	}
}
