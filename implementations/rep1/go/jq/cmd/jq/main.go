// Command jq reads a filter (first line) and a JSON document (the rest) from
// standard input, evaluates the filter on the document and prints every
// result as one line of compact JSON. If evaluation fails, the results
// produced so far are printed followed by a line containing "error".
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/peter/jq"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout, os.Stderr))
}

func run(stdin io.Reader, stdout, stderr io.Writer) int {
	data, err := io.ReadAll(stdin)
	if err != nil {
		fmt.Fprintln(stderr, "jq: reading input:", err)
		return 2
	}
	text := string(data)
	filter, doc, _ := strings.Cut(text, "\n")

	q, err := jq.Compile(filter)
	if err != nil {
		fmt.Fprintln(stderr, "jq:", err)
		return 2
	}
	input, err := jq.ParseJSON(doc)
	if err != nil {
		fmt.Fprintln(stderr, "jq:", err)
		return 2
	}

	w := bufio.NewWriterSize(stdout, 1<<16)
	var buf []byte
	runErr := q.Run(input, func(v jq.Value) error {
		buf = jq.AppendJSON(buf[:0], v)
		buf = append(buf, '\n')
		_, err := w.Write(buf)
		return err
	})
	if runErr != nil {
		if _, ok := runErr.(*jq.RuntimeError); ok {
			fmt.Fprintln(stderr, "jq: error:", runErr)
			w.WriteString("error\n")
		} else {
			fmt.Fprintln(stderr, "jq:", runErr)
		}
	}
	if err := w.Flush(); err != nil {
		return 1
	}
	return 0
}
