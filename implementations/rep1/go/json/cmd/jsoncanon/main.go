// Command jsoncanon reads one JSON document from standard input and writes its
// canonical serialization to standard output, or the line "invalid" if the
// document is not valid JSON. The exit status is 0 in both cases.
package main

import (
	"bufio"
	"io"
	"os"

	"github.com/example/jsoncanon"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout))
}

func run(in io.Reader, out io.Writer) int {
	data, err := io.ReadAll(in)
	if err != nil {
		return 1
	}
	res, err := jsoncanon.Canonicalize(data)
	if err != nil {
		res = []byte("invalid")
	}
	res = append(res, '\n')
	w := bufio.NewWriterSize(out, 1<<16)
	if _, err := w.Write(res); err != nil {
		return 1
	}
	if err := w.Flush(); err != nil {
		return 1
	}
	return 0
}
