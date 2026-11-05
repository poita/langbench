// Command sitegen generates a static website.
//
// Usage:
//
//	sitegen <input directory> <output directory>
//
// The input directory holds site.toml, content/, templates/ and static/; the
// generated site is written into the output directory (created if missing).
// The command exits 0 on success and 1 on failure, printing the error to
// standard error.
package main

import (
	"fmt"
	"os"

	"example.com/sitegen"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintf(os.Stderr, "usage: %s <input directory> <output directory>\n", os.Args[0])
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintf(os.Stderr, "sitegen: %v\n", err)
		os.Exit(1)
	}
}

func run(in, out string) error {
	site, err := sitegen.BuildDir(in)
	if err != nil {
		return err
	}
	return site.WriteDir(out)
}
