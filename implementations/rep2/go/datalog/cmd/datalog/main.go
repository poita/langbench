// Command datalog reads a Datalog program on stdin and prints the answers to
// its queries on stdout. An unsafe, unstratifiable or malformed program makes
// it print "error" (and exit 0); diagnostics go to stderr.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"

	"example.com/datalog"
	"example.com/datalog/parser"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout, os.Stderr))
}

// run implements the command and returns its exit status.
func run(stdin io.Reader, stdout, stderr io.Writer) int {
	var out bytes.Buffer // nothing is printed unless the whole program is accepted
	err := datalog.Run(stdin, &out)
	var syn *parser.SyntaxError
	switch {
	case err == nil:
		if _, err := stdout.Write(out.Bytes()); err != nil {
			fmt.Fprintln(stderr, "datalog:", err)
			return 1
		}
	case errors.Is(err, datalog.ErrUnsafe), errors.Is(err, datalog.ErrNotStratifiable), errors.As(err, &syn):
		fmt.Fprintln(stdout, "error")
		fmt.Fprintln(stderr, err)
	default:
		fmt.Fprintln(stderr, "datalog:", err)
		return 1
	}
	return 0
}
