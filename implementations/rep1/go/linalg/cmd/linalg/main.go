// Command linalg executes a script of dense linear algebra operations.
//
// Usage:
//
//	linalg <input directory> <output directory>
//
// The input directory holds commands.txt and the Matrix Market files it
// names; one result file per output matrix (or an error file) is written to
// the output directory.
package main

import (
	"fmt"
	"os"

	"example.com/linalg/internal/driver"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: linalg <input directory> <output directory>")
		os.Exit(2)
	}
	if err := driver.Run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "linalg:", err)
		os.Exit(1)
	}
}
