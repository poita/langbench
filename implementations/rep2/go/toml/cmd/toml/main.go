// Command toml converts between TOML and tagged JSON.
//
// It reads stdin: the first line is the mode, "decode" or "encode", and the
// rest is the document. In decode mode the document is parsed as TOML and
// printed as tagged JSON (or the word "error" if it is invalid). In encode mode
// the document is tagged JSON and the canonical TOML is printed.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"

	"example.com/toml"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "toml:", err)
	}
}

// run implements the I/O contract. Invalid TOML is not an error of the tool:
// it is reported on stdout as "error".
func run(in io.Reader, out io.Writer) error {
	data, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	mode, doc, _ := bytes.Cut(data, []byte{'\n'})
	var result []byte
	switch string(mode) {
	case "decode":
		root, perr := toml.Parse(doc)
		if perr != nil {
			result = []byte("error")
		} else {
			result = toml.MarshalTaggedJSON(root)
		}
	case "encode":
		root, jerr := toml.ParseTaggedJSON(doc)
		if jerr != nil {
			return jerr
		}
		if result, err = toml.MarshalTOML(root); err != nil {
			return err
		}
	default:
		return errors.New("unknown mode " + fmt.Sprintf("%q", mode))
	}
	if len(result) == 0 || result[len(result)-1] != '\n' {
		result = append(result, '\n')
	}
	_, err = out.Write(result)
	return err
}
