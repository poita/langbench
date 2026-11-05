// Command langvm reads a multi-module Vellum program from standard input,
// compiles it and runs it. Everything the program prints goes to standard
// output; a program that fails to compile prints a single diagnostic line.
// The exit code is 0 in every such case.
package main

import (
	"fmt"
	"io"
	"os"
	"runtime/debug"

	"langvm/vellum"
)

func main() {
	// The front end allocates many small nodes; trade memory for fewer GCs.
	debug.SetGCPercent(400)
	src, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "langvm: reading stdin:", err)
		os.Exit(1)
	}
	out := vellum.Run(src)
	if _, err := os.Stdout.Write(out); err != nil {
		fmt.Fprintln(os.Stderr, "langvm: writing stdout:", err)
		os.Exit(1)
	}
}
