// Command toml converts between TOML documents and tagged JSON.
//
// It reads standard input. The first line is the mode, "decode" or
// "encode"; the rest is the document.
//
// In decode mode the document is parsed as TOML 1.0.0 and printed as
// compact, key-sorted tagged JSON, or the single word "error" if it is not
// valid TOML. In encode mode the document is tagged JSON and the canonical
// TOML rendering is printed.
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"

	"example.com/toml"
	"example.com/toml/tagged"
)

func main() {
	in, err := io.ReadAll(bufio.NewReaderSize(os.Stdin, 1<<20))
	if err != nil {
		fmt.Fprintln(os.Stderr, "toml:", err)
		os.Exit(1)
	}
	out := run(in)
	if _, err := os.Stdout.Write(out); err != nil {
		os.Exit(1)
	}
}

// run processes one request (mode line plus document) and returns the output.
func run(in []byte) []byte {
	mode, doc, _ := bytes.Cut(in, []byte{'\n'})
	switch string(mode) {
	case "decode":
		t, err := toml.Parse(doc)
		if err != nil {
			return []byte("error\n")
		}
		return append(tagged.Marshal(t), '\n')
	case "encode":
		t, err := tagged.Unmarshal(doc)
		if err != nil {
			fmt.Fprintln(os.Stderr, "toml:", err)
			return []byte("error\n")
		}
		return toml.Encode(t)
	}
	fmt.Fprintf(os.Stderr, "toml: unknown mode %q\n", mode)
	return []byte("error\n")
}
