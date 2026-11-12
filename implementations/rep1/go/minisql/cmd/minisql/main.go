// Command minisql reads a SQL script from standard input, executes it against
// an in-memory database and prints the result of every SELECT to standard
// output. A statement that fails prints the line "error".
package main

import (
	"fmt"
	"io"
	"os"

	"minisql"
)

func main() {
	src, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "minisql:", err)
		os.Exit(1)
	}
	if err := minisql.New().RunScript(string(src), os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "minisql:", err)
		os.Exit(1)
	}
}
