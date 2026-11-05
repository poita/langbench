// Command commonmark reads a Markdown document from standard input and
// writes the corresponding HTML to standard output.
//
//	commonmark < input.md > output.html
package main

import (
	"fmt"
	"io"
	"os"

	"example.com/commonmark"
)

// run converts all of in to HTML on out.
func run(in io.Reader, out io.Writer) error {
	src, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	_, err = commonmark.Parse(src).WriteTo(out)
	return err
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "commonmark:", err)
		os.Exit(1)
	}
}
