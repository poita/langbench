// Command orderbook reads a stream of order commands on standard input,
// matches them in a limit order book and prints the resulting events on
// standard output. See the project README for the protocol.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/example/orderbook"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "orderbook:", err)
		os.Exit(1)
	}
}

func run(in io.Reader, out io.Writer) error {
	input, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	res, err := orderbook.Run(input)
	if err != nil {
		return err
	}
	_, err = out.Write(res)
	return err
}
