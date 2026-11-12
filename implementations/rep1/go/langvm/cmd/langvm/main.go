// Command langvm reads a multi-module Vellum program from standard input,
// compiles it and runs it. Program output goes to standard output; a rejected
// program prints one "error: <kind> at <line>:<col>" line and a program that
// panics prints "panic: <message>" after its output. The exit status is 0 in
// every such case.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"runtime/debug"

	"langvm"
)

func main() {
	// The VM allocates many short-lived values; trade some memory for speed.
	debug.SetGCPercent(300)
	input, err := io.ReadAll(bufio.NewReaderSize(os.Stdin, 1<<20))
	if err != nil {
		fmt.Fprintln(os.Stderr, "langvm: cannot read standard input:", err)
		os.Exit(2)
	}
	if err := langvm.Run(input, os.Stdout); err != nil {
		fmt.Fprintln(os.Stdout, err)
	}
}
