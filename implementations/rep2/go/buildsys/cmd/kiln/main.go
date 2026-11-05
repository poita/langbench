// Command kiln runs a Kiln session.
//
// Usage:
//
//	kiln <input directory> <output directory>
//
// The input directory holds session.txt and the initial workspace. The
// output directory receives log.txt and the final workspace under
// workspace/. Build errors are part of the log and do not affect the exit
// status.
package main

import (
	"fmt"
	"os"

	"kiln/session"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: kiln <input directory> <output directory>")
		os.Exit(2)
	}
	if err := session.RunDir(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "kiln:", err)
		os.Exit(1)
	}
}
