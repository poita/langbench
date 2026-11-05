// Command template renders a Jinja-style template.
//
// It reads a JSON context and a set of named templates from standard input
// (see the package documentation for the format), renders the first
// template and prints the result followed by a newline. Template errors are
// reported as a single line "error: <kind>" on standard output; the exit
// status is 0 in both cases.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"

	"example.com/template"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "template:", err)
		os.Exit(2)
	}
	out, err := template.Process(input)
	if err != nil {
		fmt.Fprintln(os.Stderr, "template:", err)
		os.Exit(2)
	}
	w := bufio.NewWriterSize(os.Stdout, 1<<16)
	w.WriteString(out)
	if err := w.Flush(); err != nil {
		fmt.Fprintln(os.Stderr, "template:", err)
		os.Exit(1)
	}
}
