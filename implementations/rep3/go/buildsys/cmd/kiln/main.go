// Command kiln runs a Kiln session.
//
// Usage:
//
//	kiln <input directory> <output directory>
//
// The input directory holds session.txt and the initial workspace. The output
// directory receives log.txt and workspace/, the final workspace.
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

func run(inDir, outDir string) error {
	script, err := os.ReadFile(filepath.Join(inDir, "session.txt"))
	if err != nil {
		return err
	}
	fs, err := vfs.Load(inDir, "session.txt")
	if err != nil {
		return err
	}
	log, err := session.RunScript(fs, script)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(outDir, "log.txt"), log, 0o644); err != nil {
		return err
	}
	return fs.WriteTo(filepath.Join(outDir, "workspace"))
}
