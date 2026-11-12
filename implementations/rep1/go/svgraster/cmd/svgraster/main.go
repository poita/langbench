// Command svgraster renders the SVG files listed in <input-dir>/render.txt to
// binary PPM files in <output-dir>.
//
// Usage:
//
//	svgraster <input-dir> <output-dir>
package main

import (
	"fmt"
	"os"

	"svgraster"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: svgraster <input-dir> <output-dir>")
		os.Exit(2)
	}
	if err := svgraster.RenderDir(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "svgraster:", err)
		os.Exit(1)
	}
}
