// Command toml converts between TOML documents and tagged JSON.
//
// It reads all of standard input. The first line selects the mode:
//
//	decode  parse the rest of the input as TOML and print tagged JSON
//	        (or the single word "error" if the document is invalid)
//	encode  parse the rest of the input as tagged JSON and print canonical TOML
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"github.com/example/toml"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "toml:", err)
		os.Exit(1)
	}
	nl := bytes.IndexByte(input, '\n')
	if nl < 0 {
		nl = len(input)
	}
	mode, doc := string(input[:nl]), input[min(nl+1, len(input)):]

	var out []byte
	switch mode {
	case "decode":
		root, err := toml.Parse(doc)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			out = []byte("error\n")
		} else {
			out = root.AppendJSON(make([]byte, 0, len(doc)*2+64))
			out = append(out, '\n')
		}
	case "encode":
		root, err := toml.ParseJSON(doc)
		if err != nil {
			fmt.Fprintln(os.Stderr, "toml:", err)
			os.Exit(1)
		}
		out = root.AppendTOML(make([]byte, 0, len(doc)+64))
	default:
		fmt.Fprintf(os.Stderr, "toml: unknown mode %q (want decode or encode)\n", mode)
		os.Exit(2)
	}
	if _, err := os.Stdout.Write(out); err != nil {
		os.Exit(1)
	}
}
