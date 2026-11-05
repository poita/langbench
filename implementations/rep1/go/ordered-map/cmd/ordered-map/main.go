// Command ordered-map reads a script of ordered-map commands from standard
// input and writes one response line per command to standard output.
// See the README for the command language.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/example/ordered-map/script"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ordered-map: reading stdin:", err)
		os.Exit(1)
	}
	if _, err := os.Stdout.Write(script.Execute(input)); err != nil {
		fmt.Fprintln(os.Stderr, "ordered-map: writing stdout:", err)
		os.Exit(1)
	}
}
