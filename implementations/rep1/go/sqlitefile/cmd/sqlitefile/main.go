// Command sqlitefile answers the queries in an input directory against the
// SQLite database stored there.
//
// Usage:
//
//	sqlitefile <input directory> <output directory>
//
// The input directory holds one *.sqlite file and queries.txt, one query per
// line. For the n-th query the file NNN.txt (n zero-padded to three digits) is
// written to the output directory. A failed query produces the single line
// "error"; the exit status is still 0.
package main

import (
	"bufio"
	"bytes"
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
	matches, err := filepath.Glob(filepath.Join(globEscape(inDir), "*.sqlite"))
	if err != nil {
		return err
	}
	if len(matches) != 1 {
		return fmt.Errorf("expected exactly one .sqlite file in %s, found %d", inDir, len(matches))
	}
	qdata, err := os.ReadFile(filepath.Join(inDir, "queries.txt"))
	if err != nil {
		return err
	}
	queries := strings.Split(strings.TrimSuffix(string(qdata), "\n"), "\n")

	db, dbErr := sqlitefile.Open(matches[0])
	for i, q := range queries {
		var out bytes.Buffer
		w := bufio.NewWriter(&out)
		var lines []string
		err := dbErr
		if err == nil {
			lines, err = db.Exec(q)
		}
		if err != nil {
			w.WriteString("error\n")
		} else {
			for _, l := range lines {
				w.WriteString(l)
				w.WriteByte('\n')
			}
		}
		w.Flush()
		name := filepath.Join(outDir, fmt.Sprintf("%03d.txt", i+1))
		if err := os.WriteFile(name, out.Bytes(), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// globEscape escapes glob metacharacters in a directory path.
func globEscape(s string) string {
	return strings.NewReplacer(`\`, `\\`, `*`, `\*`, `?`, `\?`, `[`, `\[`).Replace(s)
}
