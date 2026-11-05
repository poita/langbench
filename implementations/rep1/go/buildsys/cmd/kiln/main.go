// Command kiln runs a Kiln session: it loads a workspace and session script
// from an input directory, runs the session, and writes the log and the final
// workspace to an output directory.
//
// Usage:
//
//	kiln <input directory> <output directory>
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"buildsys/session"
	"buildsys/vfs"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: kiln <input directory> <output directory>")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "kiln:", err)
		os.Exit(1)
	}
}

func run(in, out string) error {
	script, err := os.ReadFile(filepath.Join(in, "session.txt"))
	if err != nil {
		return err
	}
	steps, err := session.Parse(script)
	if err != nil {
		return err
	}
	fs := vfs.New()
	if err := fs.LoadDir(in, func(rel string) bool { return rel == "session.txt" }); err != nil {
		return err
	}
	log := session.Run(fs, steps)
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(out, "log.txt"), log, 0o644); err != nil {
		return err
	}
	return fs.WriteDir(filepath.Join(out, "workspace"))
}
