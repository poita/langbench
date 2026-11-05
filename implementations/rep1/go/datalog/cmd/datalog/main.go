// Command datalog reads a Datalog program from standard input and prints the
// answers to its queries.
//
// If the program is unsafe or not stratifiable it prints "error" and exits 0.
// Malformed input prints a diagnostic on standard error and exits with
// status 2.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/example/datalog"
)

func main() {
	src, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "datalog:", err)
		os.Exit(1)
	}
	var out bytes.Buffer
	switch err := datalog.Solve(src, &out); {
	case err == nil:
		os.Stdout.Write(out.Bytes())
	case errors.Is(err, datalog.ErrUnsafe), errors.Is(err, datalog.ErrNotStratifiable):
		fmt.Fprintln(os.Stderr, err)
		fmt.Println("error")
	default:
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}
