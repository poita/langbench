// Command datalog reads a Datalog program on standard input and writes the
// answers to its queries on standard output. A program that is unsafe or not
// stratifiable (or malformed) prints "error". The exit status is 0 either way.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"

	"datalog"
)

func main() {
	src, err := io.ReadAll(bufio.NewReaderSize(os.Stdin, 1<<20))
	if err != nil {
		fmt.Fprintln(os.Stderr, "datalog:", err)
		os.Exit(1)
	}
	out, err := datalog.Run(src)
	if err != nil {
		fmt.Fprintln(os.Stderr, "datalog:", err)
		fmt.Println("error")
		return
	}
	if _, err := os.Stdout.Write(out); err != nil {
		os.Exit(1)
	}
}
