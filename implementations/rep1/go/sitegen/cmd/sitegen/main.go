// Command sitegen generates a static website from a site source directory.
//
// Usage:
//
//	sitegen <input directory> <output directory>
//
// The input directory holds site.toml, content/, templates/ and static/; the
// output directory is created if it does not exist. The exit status is 0 on
// success, 1 if the site could not be generated and 2 on a usage error.
package main

import (
	"fmt"
	"io"
	"os"

	"example.com/sitegen"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stderr))
}

func run(args []string, stderr io.Writer) int {
	if len(args) != 2 {
		fmt.Fprintln(stderr, "usage: sitegen <input directory> <output directory>")
		return 2
	}
	in, out := args[0], args[1]
	if err := os.MkdirAll(out, 0o755); err != nil {
		fmt.Fprintln(stderr, "sitegen:", err)
		return 1
	}
	if err := sitegen.Build(os.DirFS(in), sitegen.DirSink(out)); err != nil {
		fmt.Fprintln(stderr, "sitegen:", err)
		return 1
	}
	return 0
}
