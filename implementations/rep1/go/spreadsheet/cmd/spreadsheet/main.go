// Command spreadsheet reads spreadsheet commands from standard input and
// writes the results of get and dump to standard output.
//
// Commands (one per line):
//
//	set <CELL> <content>
//	get <CELL>
//	clear <CELL>
//	dump
package main

import (
	"fmt"
	"io"
	"os"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "spreadsheet:", err)
		os.Exit(1)
	}
	if _, err := os.Stdout.Write(Run(string(in))); err != nil {
		fmt.Fprintln(os.Stderr, "spreadsheet:", err)
		os.Exit(1)
	}
}
