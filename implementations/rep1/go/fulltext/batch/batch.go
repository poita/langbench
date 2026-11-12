package batch

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"

	"fulltext"
)

// Run loads the corpus and queries from input, evaluates every query and
// writes results.txt and stats.txt into output (created if missing).
func Run(input, output string) error {
	docs, err := LoadDocuments(input)
	if err != nil {
		return err
	}
	qdata, err := os.ReadFile(filepath.Join(input, "queries.txt"))
	if err != nil {
		return err
	}
	eng := fulltext.New(docs)
	if err := os.MkdirAll(output, 0o755); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(output, "results.txt"), func(w io.Writer) error {
		return WriteResults(w, eng, ParseQueries(string(qdata)))
	}); err != nil {
		return err
	}
	return writeFile(filepath.Join(output, "stats.txt"), func(w io.Writer) error {
		return WriteStats(w, eng.Stats())
	})
}

func writeFile(path string, fill func(io.Writer) error) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	bw := bufio.NewWriterSize(f, 1<<16)
	if err := fill(bw); err != nil {
		f.Close()
		return err
	}
	if err := bw.Flush(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// WriteResults runs the queries and writes the results.txt format:
//
//	QUERY <number> <text>
//	HITS <h>
//	<rank>\t<id>\t<score>\t<snippet>
func WriteResults(w io.Writer, eng *fulltext.Engine, queries []Query) error {
	bw := bufio.NewWriter(w)
	for _, q := range queries {
		hits := eng.Search(q.Text, q.K)
		fmt.Fprintf(bw, "QUERY %d %s\nHITS %d\n", q.Number, q.Text, len(hits))
		for i, h := range hits {
			bw.WriteString(strconv.Itoa(i + 1))
			bw.WriteByte('\t')
			bw.WriteString(h.DocID)
			bw.WriteByte('\t')
			bw.WriteString(strconv.FormatFloat(h.Score, 'f', 4, 64))
			bw.WriteByte('\t')
			bw.WriteString(h.Snippet)
			bw.WriteByte('\n')
		}
	}
	return bw.Flush()
}

// WriteStats writes the four-line stats.txt format.
func WriteStats(w io.Writer, s fulltext.Stats) error {
	_, err := fmt.Fprintf(w, "documents %d\ntokens %d\nterms %d\navgdl %.4f\n",
		s.Documents, s.Tokens, s.Terms, s.AvgDocLen)
	return err
}
