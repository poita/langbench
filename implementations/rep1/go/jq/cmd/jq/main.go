// Command jq reads one filter and one JSON document from standard input,
// evaluates the filter on the document and prints each result as compact JSON,
// one per line.
//
// Input format: the first line is the filter; everything after the first
// newline is the JSON document. If evaluation raises an error, the results
// produced before it are printed, followed by a line containing "error". The
// exit status is 0 in all cases except a failure to read stdin or write
// stdout.
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"

	"example.com/jq"
	"example.com/jq/value"
)

func main() {
	if err := run(os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "jq:", err)
		os.Exit(1)
	}
}

func run(stdin io.Reader, stdout, stderr io.Writer) error {
	data, err := io.ReadAll(stdin)
	if err != nil {
		return err
	}
	w := bufio.NewWriterSize(stdout, 64<<10)
	if err := process(data, w, stderr); err != nil {
		return err
	}
	return w.Flush()
}

// process evaluates the filter in data and writes results to w. Evaluation
// errors are reported as an "error" line (and a message on stderr), not as a
// Go error.
func process(data []byte, w *bufio.Writer, stderr io.Writer) error {
	filter, doc := data, []byte(nil)
	if i := bytes.IndexByte(data, '\n'); i >= 0 {
		filter, doc = data[:i], data[i+1:]
	}
	fail := func(err error) error {
		fmt.Fprintln(stderr, err)
		_, werr := w.WriteString("error\n")
		return werr
	}
	q, err := jq.Compile(string(filter))
	if err != nil {
		return fail(err)
	}
	input, err := jq.ParseJSON(doc)
	if err != nil {
		return fail(err)
	}
	var buf []byte
	var werr error
	err = q.Run(input, func(v jq.Value) error {
		buf = value.Append(buf[:0], v)
		buf = append(buf, '\n')
		_, werr = w.Write(buf)
		return werr
	})
	if werr != nil {
		return werr
	}
	if err != nil {
		return fail(err)
	}
	return nil
}
