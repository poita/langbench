// Command mime parses a mailbox (an mbox file or a directory of .eml files)
// and writes a normalised dump of every message, plus the decoded bytes of
// every attachment, into an output directory.
//
// Usage:
//
//	mime <input path> <output directory>
package main

import (
	"fmt"
	"os"

	"mimedump/export"
	"mimedump/mailbox"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: mime <input path> <output directory>")
		os.Exit(2)
	}
	mb, err := mailbox.Open(os.Args[1])
	if err == nil {
		err = export.Write(mb, os.Args[2])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "mime:", err)
		os.Exit(1)
	}
}
