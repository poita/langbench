package fulltext

import (
	"bufio"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"example.com/fulltext/query"
)

// DefaultK is the result limit before any %k directive.
const DefaultK = 10

// LoadDir builds an index from the regular files named *.txt directly inside
// dir/docs. The document id is the file name without ".txt". A missing docs
// directory yields an empty index.
func LoadDir(dir string) (*Index, error) {
	b := NewBuilder()
	entries, err := os.ReadDir(filepath.Join(dir, "docs"))
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	for _, e := range entries {
		name := e.Name()
		if !e.Type().IsRegular() || !strings.HasSuffix(name, ".txt") {
			continue
		}
		text, err := os.ReadFile(filepath.Join(dir, "docs", name))
		if err != nil {
			return nil, err
		}
		b.Add(strings.TrimSuffix(name, ".txt"), text)
	}
	return b.Build(), nil
}

// QueryLine is one query of a queries file.
type QueryLine struct {
	Number int    // 1-based query number
	Text   string // query text, whitespace-stripped
	K      int    // result limit in force
}

// ParseQueryFile splits the contents of a queries file into queries. Blank
// lines and lines starting with '#' are ignored, and a line "%k <digits>"
// sets the result limit for the queries after it.
func ParseQueryFile(data string) []QueryLine {
	var out []QueryLine
	k := DefaultK
	for _, line := range strings.Split(data, "\n") {
		line = query.TrimSpace(line)
		switch {
		case line == "" || line[0] == '#':
		case isDirective(line):
			rest := strings.TrimLeft(line[2:], " \t")
			n, err := strconv.Atoi(strings.TrimRight(rest, " \t"))
			if err != nil {
				n = int(^uint(0) >> 1)
			}
			k = n
		default:
			out = append(out, QueryLine{Number: len(out) + 1, Text: line, K: k})
		}
	}
	return out
}

// isDirective reports whether line is "%k", spaces/tabs, digits, optional
// spaces/tabs.
func isDirective(line string) bool {
	if !strings.HasPrefix(line, "%k") {
		return false
	}
	rest := line[2:]
	trimmed := strings.TrimLeft(rest, " \t")
	if len(trimmed) == len(rest) {
		return false
	}
	digits := strings.TrimRight(trimmed, " \t")
	if digits == "" {
		return false
	}
	for i := 0; i < len(digits); i++ {
		if digits[i] < '0' || digits[i] > '9' {
			return false
		}
	}
	return true
}

// WriteResults runs every query of a queries file against the index and
// writes the ranked answer in the results.txt format: per query a
// "QUERY <n> <text>" line, a "HITS <h>" line, then one
// "<rank>\t<id>\t<score>\t<snippet>" line per hit.
func (ix *Index) WriteResults(w io.Writer, queries []QueryLine) error {
	bw := bufio.NewWriterSize(w, 1<<16)
	var buf []byte
	for _, q := range queries {
		hits := ix.Search(q.Text, q.K)
		buf = append(buf[:0], "QUERY "...)
		buf = strconv.AppendInt(buf, int64(q.Number), 10)
		buf = append(buf, ' ')
		buf = append(buf, q.Text...)
		buf = append(buf, "\nHITS "...)
		buf = strconv.AppendInt(buf, int64(len(hits)), 10)
		buf = append(buf, '\n')
		for i, h := range hits {
			buf = strconv.AppendInt(buf, int64(i+1), 10)
			buf = append(buf, '\t')
			buf = append(buf, h.DocID...)
			buf = append(buf, '\t')
			buf = strconv.AppendFloat(buf, h.Score, 'f', 4, 64)
			buf = append(buf, '\t')
			buf = append(buf, h.Snippet...)
			buf = append(buf, '\n')
		}
		if _, err := bw.Write(buf); err != nil {
			return err
		}
	}
	return bw.Flush()
}
