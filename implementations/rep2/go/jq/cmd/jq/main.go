// Command jq reads a filter (first line) and a JSON document (the rest) from
// standard input, evaluates the filter and prints every result as compact
// JSON, one per line. If evaluation fails it prints "error" after the results
// produced so far. See the README for details.
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"

	"example.com/jq"
)

func main() { os.Exit(run(os.Stdin, os.Stdout, os.Stderr)) }

func run(stdin io.Reader, stdout, stderr io.Writer) int {
	data, err := io.ReadAll(stdin)
	if err != nil {
		fmt.Fprintln(stderr, "jq:", err)
		return 2
	}
	filter, doc := data, []byte(nil)
	if i := bytes.IndexByte(data, '\n'); i >= 0 {
		filter, doc = data[:i], data[i+1:]
	}
	prog, err := jq.Compile(string(bytes.TrimSuffix(filter, []byte("\r"))))
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	input, err := jq.ParseJSON(doc)
	if err != nil {
		fmt.Fprintln(stderr, "jq:", err)
		return 2
	}

	w := bufio.NewWriterSize(stdout, 64<<10)
	var buf []byte
	err = prog.Run(input, func(v jq.Value) error {
		buf = jq.AppendJSON(buf[:0], v)
		buf = append(buf, '\n')
		_, werr := w.Write(buf)
		return werr
	})
	if err != nil {
		if _, ok := err.(*jq.Error); ok {
			fmt.Fprintln(stderr, "jq: error:", err)
			w.WriteString("error\n")
		} else {
			fmt.Fprintln(stderr, "jq:", err)
		}
	}
	if err := w.Flush(); err != nil {
		return 1
	}
	return 0
}
