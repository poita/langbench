// Package batch implements the directory-based batch mode used by the
// command-line tool: load documents and a query file from an input directory,
// run every query and write results.txt and stats.txt.
package batch

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"fulltext"
	"fulltext/analysis"
)

// LoadDocuments reads every regular file named *.txt directly inside
// <input>/docs. The document id is the file name without ".txt". A missing
// docs directory yields no documents.
func LoadDocuments(input string) ([]fulltext.Document, error) {
	dir := filepath.Join(input, "docs")
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var docs []fulltext.Document
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".txt") {
			continue
		}
		path := filepath.Join(dir, name)
		if fi, err := os.Stat(path); err != nil || !fi.Mode().IsRegular() {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		docs = append(docs, fulltext.Document{ID: strings.TrimSuffix(name, ".txt"), Text: string(data)})
	}
	return docs, nil
}

// Query is one numbered query of a query file with its result limit.
type Query struct {
	Number int    // 1-based
	Text   string // the stripped line, as echoed in the output
	K      int    // result limit in force
}

// DefaultK is the result limit before any %k directive.
const DefaultK = 10

// ParseQueries parses the contents of a queries.txt file. Blank lines and
// comments (first character '#') are skipped; "%k <digits>" sets the limit for
// the queries after it; every other line is a query.
func ParseQueries(data string) []Query {
	var out []Query
	k := DefaultK
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimFunc(line, analysis.IsSpace)
		switch {
		case line == "", line[0] == '#':
		default:
			if n, ok := parseDirective(line); ok {
				k = n
				continue
			}
			out = append(out, Query{Number: len(out) + 1, Text: line, K: k})
		}
	}
	return out
}

// parseDirective recognises "%k" followed by blanks, digits and optional blanks.
func parseDirective(line string) (int, bool) {
	rest, ok := strings.CutPrefix(line, "%k")
	if !ok {
		return 0, false
	}
	blank := func(r rune) bool { return r == ' ' || r == '\t' }
	trimmed := strings.TrimLeftFunc(rest, blank)
	if len(trimmed) == len(rest) {
		return 0, false
	}
	digits := strings.TrimRightFunc(trimmed, blank)
	if digits == "" {
		return 0, false
	}
	for _, c := range digits {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	n, err := strconv.Atoi(digits)
	if err != nil {
		n = int(^uint(0) >> 1) // absurdly large: effectively unlimited
	}
	return n, true
}
