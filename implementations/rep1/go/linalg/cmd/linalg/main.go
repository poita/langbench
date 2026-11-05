// Command linalg runs a script of dense linear algebra operations.
//
//	linalg <input directory> <output directory>
//
// See the README for the file formats.
package main

import (
	"fmt"
	"os"

	"linalg/internal/driver"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: linalg <input directory> <output directory>")
		os.Exit(2)
	}
	if err := driver.Run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "linalg:", err)
	}
}
