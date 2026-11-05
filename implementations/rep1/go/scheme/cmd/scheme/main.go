// Command scheme reads a Scheme program from standard input, evaluates it,
// and writes the printed results and display output to standard output. A
// runtime error ends the run with an "error: <category>" line; the exit code
// is 0 in every case.
package main

import (
	"errors"
	"fmt"
	"io"
	"os"

	"example.com/scheme"
)

func main() {
	src, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "scheme:", err)
		os.Exit(2)
	}
	in := scheme.New()
	runErr := in.Run(src)
	out := in.Output()
	var se *scheme.Error
	if errors.As(runErr, &se) {
		out = append(out, "error: "+se.Category+"\n"...)
	}
	if _, err := os.Stdout.Write(out); err != nil {
		os.Exit(2)
	}
}
