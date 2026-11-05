// Command kvstore runs a Tessera command script.
//
// Usage:
//
//	kvstore <input dir> <output dir>
//
// The input directory holds commands.txt and optionally main.tdb and
// main.twal. The output directory receives results.txt, main.tdb and
// main.twal.
package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"example.com/kvstore"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: kvstore <input dir> <output dir>")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "kvstore:", err)
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
	walFile, err := readOptional(filepath.Join(inDir, "main.twal"))
	if err != nil {
		return err
	}
	results, mainOut, walOut := kvstore.RunScript(script, mainFile, walFile)
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	for _, f := range []struct {
		name string
		data []byte
	}{{"results.txt", results}, {"main.tdb", mainOut}, {"main.twal", walOut}} {
		if err := os.WriteFile(filepath.Join(outDir, f.name), f.data, 0o644); err != nil {
			return err
		}
	}
	return nil
}
