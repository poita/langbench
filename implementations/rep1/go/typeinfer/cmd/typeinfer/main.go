// Command typeinfer reads a program in a small ML-like language from standard
// input and prints the principal type of every top-level declaration, or an
// "error: <kind>" line for each declaration that does not type-check.
//
//	typeinfer < program.ml
//
// The exit status is 0 whenever the input could be read: a type error is a
// normal result. Syntax errors (outside the contract) are reported on stderr
// after the results of the declarations that preceded them.
package main

import (
	"fmt"
	"io"
	"os"
	"runtime/debug"

	"example.com/typeinfer"
)

func main() {
	// Inference and printing recurse as deep as the program nests.
	debug.SetMaxStack(4 << 30)
	debug.SetGCPercent(400)

	if err := run(os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "typeinfer:", err)
		os.Exit(1)
	}
}

// run reads a program from in, writes one line per declaration to out, and
// reports a syntax error, if any, to errw. The returned error is an I/O error.
func run(in io.Reader, out, errw io.Writer) error {
	src, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	results, perr := typeinfer.NewChecker().Check(src)

	var buf []byte
	for _, r := range results {
		buf = r.Append(buf)
	}
	if _, err := out.Write(buf); err != nil {
		return err
	}
	if perr != nil {
		fmt.Fprintln(errw, "typeinfer:", perr)
	}
	return nil
}
