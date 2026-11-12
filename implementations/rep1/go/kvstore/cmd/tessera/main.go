// Command tessera runs a Tessera command script against a database.
//
// Usage:
//
//	tessera <input dir> <output dir>
//
// The input directory holds commands.txt and, optionally, main.tdb and
// main.twal. The output directory receives results.txt, main.tdb and
// main.twal.
package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"example.com/tessera"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintf(os.Stderr, "usage: %s <input dir> <output dir>\n", filepath.Base(os.Args[0]))
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "tessera:", err)
		os.Exit(1)
	}
}

// readOptional reads a file, returning nil if it does not exist.
func readOptional(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	return b, err
}

func run(inDir, outDir string) error {
	script, err := os.ReadFile(filepath.Join(inDir, "commands.txt"))
	if err != nil {
		return err
	}
	mainFile, err := readOptional(filepath.Join(inDir, "main.tdb"))
	if err != nil {
		return err
	}
	logFile, err := readOptional(filepath.Join(inDir, "main.twal"))
	if err != nil {
		return err
	}
	out := tessera.RunScript(mainFile, logFile, script)
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	for name, data := range map[string][]byte{
		"results.txt": out.Results,
		"main.tdb":    out.DatabaseTDB,
		"main.twal":   out.LogTWAL,
	} {
		if err := os.WriteFile(filepath.Join(outDir, name), data, 0o644); err != nil {
			return err
		}
	}
	return nil
}
