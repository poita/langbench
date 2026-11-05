// Command toml converts between TOML and tagged JSON.
//
// It reads all of standard input. The first line is the mode, "decode" or
// "encode"; the rest is the document. In decode mode the document is parsed
// as TOML 1.0.0 and printed as tagged JSON, or "error" if it is invalid. In
// encode mode the document is tagged JSON and the canonical TOML is printed.
package main

import (
	"bytes"
	"io"
	"os"

	"github.com/example/toml"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout))
}

func run(in io.Reader, out io.Writer) int {
	input, err := io.ReadAll(in)
	if err != nil {
		return 1
	}
	mode, doc, _ := bytes.Cut(input, []byte("\n"))
	var res []byte
	switch string(mode) {
	case "decode":
		t, err := toml.Parse(doc)
		if err != nil {
			res = []byte("error\n")
		} else {
			res = append(t.TaggedJSON(), '\n')
		}
	case "encode":
		t, err := toml.ParseTaggedJSON(doc)
		if err != nil {
			res = []byte("error\n")
		} else {
			res = t.TOML()
		}
	default:
		return 2
	}
	if _, err := out.Write(res); err != nil {
		return 1
	}
	return 0
}
