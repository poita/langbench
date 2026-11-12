// Command fulltext indexes the documents in an input directory, runs the
// queries in its queries.txt and writes results.txt and stats.txt.
//
// Usage:
//
//	fulltext <input directory> <output directory>
package main

import (
	"fmt"
	"os"

	"fulltext/batch"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: fulltext <input directory> <output directory>")
		os.Exit(2)
	}
	if err := batch.Run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "fulltext:", err)
		os.Exit(1)
	}
}
