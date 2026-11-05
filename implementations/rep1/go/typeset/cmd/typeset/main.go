// Command typeset reads a Codexa document directory and writes its layout.
//
// Usage:
//
//	typeset <input directory> <output directory>
//
// The input directory holds document.cdx and optionally settings.cfg. Font
// metrics and hyphenation patterns are read from ./data relative to the
// current working directory. On success layout.txt and report.txt are
// written to the output directory; an invalid document produces error.txt
// instead. The exit status is 0 in both cases.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"typeset"
)

func readOptional(path string) ([]byte, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	return b, true
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: typeset <input directory> <output directory>")
		os.Exit(2)
	}
	in, out := os.Args[1], os.Args[2]
	res, err := typeset.LoadResources("data")
	if err != nil {
		fmt.Fprintln(os.Stderr, "typeset:", err)
		os.Exit(1)
	}
	var input typeset.Input
	input.Document, input.HasDocument = readOptional(filepath.Join(in, "document.cdx"))
	input.Settings, input.HasSettings = readOptional(filepath.Join(in, "settings.cfg"))
	result := typeset.Typeset(input, res)

	if err := os.MkdirAll(out, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "typeset:", err)
		os.Exit(1)
	}
	write := func(name, content string) {
		if err := os.WriteFile(filepath.Join(out, name), []byte(content), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "typeset:", err)
			os.Exit(1)
		}
	}
	if result.Err != nil {
		write("error.txt", result.ErrorText())
		return
	}
	write("layout.txt", result.Layout)
	write("report.txt", result.Report)
}
