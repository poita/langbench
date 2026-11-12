// Command cardgame reads a Spiremark match file on stdin, simulates the match
// and writes the event log and inspection blocks to stdout.
package main

import (
	"fmt"
	"os"

	"github.com/spiremark/cardgame/match"
)

func main() {
	if err := match.Run(os.Stdin, os.Stdout, match.Options{}); err != nil {
		fmt.Fprintln(os.Stderr, "cardgame:", err)
		os.Exit(1)
	}
}
