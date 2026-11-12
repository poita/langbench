// Command commonmark reads a Markdown document from standard input and writes
// the corresponding HTML to standard output.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"

	"example.com/commonmark"
)

func run(in io.Reader, out io.Writer) error {
	src, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	w := bufio.NewWriterSize(out, 1<<16)
	if _, err := w.WriteString(commonmark.ToHTML(string(src))); err != nil {
		return err
	}
	return w.Flush()
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "commonmark:", err)
		os.Exit(1)
	}
}
