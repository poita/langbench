// Command orderbook reads limit order book commands from standard input and
// writes the resulting events to standard output.
//
// Usage:
//
//	orderbook < commands.txt > events.txt
//
// The first input line is the number of commands N; N command lines follow.
// See the README for the command and event formats.
package main

import (
	"fmt"
	"os"

	"github.com/peteralexander/orderbook/protocol"
)

func main() {
	if len(os.Args) > 1 {
		fmt.Fprintln(os.Stderr, "usage: orderbook < commands > events")
		os.Exit(2)
	}
	if err := protocol.Run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "orderbook:", err)
		os.Exit(1)
	}
}
