// Command jq reads a filter (first line) and one JSON document (the rest) from
// standard input and prints every result of the filter as compact JSON, one per
// line. If evaluation fails, the results produced so far are printed followed by
// a line containing "error". The exit status is always 0.
package main

import (
	"bufio"
	"io"
	"os"
	"strings"

	"example.com/jq"
)

func main() {
	run(os.Stdin, os.Stdout)
}

// run implements the command: all of in is the filter line plus the document.
func run(in io.Reader, w io.Writer) {
	data, err := io.ReadAll(in)
	out := bufio.NewWriterSize(w, 64*1024)
	defer out.Flush()
	if err != nil {
		out.WriteString("error\n")
		return
	}
	src := string(data)
	filterText, doc, _ := strings.Cut(src, "\n")
	filter, err := jq.Compile(filterText)
	if err != nil {
		out.WriteString("error\n")
		return
	}
	input, err := jq.ParseJSONString(doc)
	if err != nil {
		out.WriteString("error\n")
		return
	}
	var buf []byte
	err = filter.Run(input, func(v jq.Value) error {
		buf = jq.AppendJSON(buf[:0], v)
		buf = append(buf, '\n')
		_, werr := out.Write(buf)
		return werr
	})
	if err != nil {
		out.WriteString("error\n")
	}
}
