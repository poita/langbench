// Command cardgame reads a Spiremark match file on stdin and writes the
// deterministic event log to stdout.
package main

import (
	"bufio"
	"fmt"
	"os"

	"cardgame"
)

func main() {
	w := bufio.NewWriterSize(os.Stdout, 1<<16)
	err := cardgame.Run(os.Stdin, w)
	if ferr := w.Flush(); err == nil {
		err = ferr
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "cardgame:", err)
		os.Exit(1)
	}
}
