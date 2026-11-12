// Command typeset is the command-line front end of the Codexa typesetting
// engine.
//
// Usage:
//
//	typeset <input directory> <output directory>
//
// The input directory holds document.cdx and optionally settings.cfg; the
// result is written to layout.txt and report.txt (or error.txt) in the output
// directory. Font metrics and hyphenation patterns are read from the "data"
// directory relative to the current working directory.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"typeset"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: typeset <input directory> <output directory>")
		os.Exit(2)
	}
	in, out := os.Args[1], os.Args[2]
	res, err := typeset.Typeset(os.DirFS(in), os.DirFS("data"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "typeset:", err)
		os.Exit(1)
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "typeset:", err)
		os.Exit(1)
	}
	for name, data := range res.Files {
		if err := os.WriteFile(filepath.Join(out, name), data, 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "typeset:", err)
			os.Exit(1)
		}
	}
}
