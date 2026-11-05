// Command jq reads one filter (the first line) and one JSON document (the
// rest) from standard input, evaluates the filter against the document and
// prints every result as compact JSON, one per line. If evaluation fails,
// the results produced before the error are printed, followed by a line
// containing "error". The exit status is 0 in every case.
package main

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"os"

	"jq"
	"jq/value"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout))
}

func run(stdin io.Reader, stdout io.Writer) int {
	data, err := io.ReadAll(stdin)
	if err != nil {
		return 1
	}
	filter, doc := data, []byte(nil)
	if i := bytes.IndexByte(data, '\n'); i >= 0 {
		filter, doc = data[:i], data[i+1:]
	}
	w := bufio.NewWriterSize(stdout, 1<<16)
	defer w.Flush()

	q, err := jq.Compile(string(bytes.TrimRight(filter, "\r")))
	if err != nil {
		w.WriteString("error\n")
		return 0
	}
	input, err := value.Parse(doc)
	if err != nil {
		w.WriteString("error\n")
		return 0
	}
	var buf []byte
	err = q.Run(input, func(v value.Value) error {
		buf = value.AppendJSON(buf[:0], v)
		buf = append(buf, '\n')
		_, werr := w.Write(buf)
		return werr
	})
	if err != nil {
		var jerr *jq.Error
		if errors.As(err, &jerr) {
			w.WriteString("error\n")
		}
	}
	return 0
}
