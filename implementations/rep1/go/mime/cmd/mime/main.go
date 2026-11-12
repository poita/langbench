// Command mime parses a mailbox (an mbox file or a directory of .eml files)
// and writes a normalised dump of each message plus its attachments.
//
// Usage:
//
//	mime <input path> <output directory>
package main

import (
	"fmt"
	"os"

	"example.com/mime/dump"
	"example.com/mime/mailbox"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: mime <input path> <output directory>")
		os.Exit(2)
	}
	sources, err := mailbox.Load(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "mime:", err)
		os.Exit(1)
	}
	if err := dump.WriteAll(os.Args[2], sources); err != nil {
		fmt.Fprintln(os.Stderr, "mime:", err)
		os.Exit(1)
	}
}
