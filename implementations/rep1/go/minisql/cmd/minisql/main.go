// Command minisql reads a SQL script from standard input, executes it against
// an in-memory database and prints the result of every SELECT to standard
// output. A failing statement prints "error" and execution continues.
package main

import (
	"fmt"
	"io"
	"os"

	"example.com/minisql"
)

// run reads a script from in and writes the query output to out.
func run(in io.Reader, out io.Writer) error {
	script, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	return minisql.New().RunScript(string(script), out)
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "minisql:", err)
		os.Exit(1)
	}
}
