// Command scheme reads a Scheme program from standard input, evaluates it,
// and writes the results to standard output.
//
// Every top-level value that is not void is printed on its own line, along
// with whatever display and newline emit. A runtime error ends the run with a
// final "error: <category>" line; the exit status is still 0.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"

	"example.com/scheme"
)

func main() {
	src, err := io.ReadAll(bufio.NewReader(os.Stdin))
	if err != nil {
		fmt.Fprintln(os.Stderr, "scheme:", err)
		os.Exit(2)
	}
	out := bufio.NewWriter(os.Stdout)
	in := scheme.New(out)
	err = in.Run(string(src))
	var rt *scheme.Error
	switch {
	case err == nil:
	case errors.As(err, &rt):
		fmt.Fprintf(out, "error: %s\n", rt.Kind)
	default:
		out.Flush()
		fmt.Fprintln(os.Stderr, "scheme:", err)
		os.Exit(2)
	}
	out.Flush()
}
