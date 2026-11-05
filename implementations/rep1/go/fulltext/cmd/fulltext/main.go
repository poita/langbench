// Command fulltext indexes a corpus and answers a file of queries.
//
// Usage:
//
//	fulltext <input directory> <output directory>
//
// The input directory holds docs/<id>.txt documents and queries.txt. The
// tool writes results.txt and stats.txt into the output directory.
package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"

	"example.com/fulltext"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: fulltext <input directory> <output directory>")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "fulltext:", err)
		os.Exit(1)
	}
}

func run(in, out string) error {
	ix, err := fulltext.LoadDir(in)
	if err != nil {
		return err
	}
	data, err := os.ReadFile(filepath.Join(in, "queries.txt"))
	if err != nil {
		return err
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	f, err := os.Create(filepath.Join(out, "results.txt"))
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	err = ix.WriteResults(w, fulltext.ParseQueryFile(string(data)))
	if err == nil {
		err = w.Flush()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(out, "stats.txt"), []byte(ix.Stats().String()), 0o644)
}
