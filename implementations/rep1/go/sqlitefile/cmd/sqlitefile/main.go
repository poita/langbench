// Command sqlitefile answers a batch of queries against a SQLite 3 database.
//
// Usage:
//
//	sqlitefile <input directory> <output directory>
//
// The input directory holds one *.sqlite file and a queries.txt with one query
// per line. For query n the tool writes NNN.txt (n zero-padded to three digits)
// into the output directory: the result rows, or the single line "error".
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"sqlitefile"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: sqlitefile <input directory> <output directory>")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "sqlitefile:", err)
		os.Exit(1)
	}
}

func run(inDir, outDir string) error {
	dbPath, err := findDatabase(inDir)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(filepath.Join(inDir, "queries.txt"))
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n")
	if len(raw) == 0 {
		lines = nil
	}

	// An unreadable database makes every query an error rather than a crash.
	db, dbErr := sqlitefile.Open(dbPath)

	var buf []byte
	for i, line := range lines {
		buf = buf[:0]
		if dbErr == nil {
			buf, err = db.Exec(strings.TrimSuffix(line, "\r"), buf)
		} else {
			err = dbErr
		}
		if err != nil {
			buf = append(buf[:0], "error\n"...)
		}
		name := filepath.Join(outDir, fmt.Sprintf("%03d.txt", i+1))
		if err := os.WriteFile(name, buf, 0o644); err != nil {
			return err
		}
	}
	return nil
}

func findDatabase(dir string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sqlite") {
			return filepath.Join(dir, e.Name()), nil
		}
	}
	return "", fmt.Errorf("no .sqlite file in %s", dir)
}
