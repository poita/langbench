// Command chess-perft answers perft and divide queries read from standard
// input, one per line, writing one result per query to standard output.
//
// A query is a six-field FEN record followed by a depth, or by the word
// "divide" and a depth:
//
//	<placement> <side> <castling> <ep> <halfmove> <fullmove> <depth>
//	<placement> <side> <castling> <ep> <halfmove> <fullmove> divide <depth>
//
// A perft query prints the leaf-node count. A divide query prints one
// "<move> <count>" line per legal root move, sorted by move text, followed by
// "total <n>".
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/example/chess-perft/chess"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "chess-perft:", err)
		os.Exit(1)
	}
}

// run executes every query read from in, writing the results to out. It stops
// at the first malformed query, after writing the results of earlier ones.
func run(in io.Reader, out io.Writer) error {
	w := bufio.NewWriter(out)
	defer w.Flush()

	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for lineNo := 1; sc.Scan(); lineNo++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		q, err := parseQuery(line)
		if err != nil {
			w.Flush()
			return fmt.Errorf("line %d: %w", lineNo, err)
		}
		q.answer(w)
	}
	return sc.Err()
}

// query is one parsed input line.
type query struct {
	pos    *chess.Position
	depth  int
	divide bool
}

// parseQuery parses a line of the form described in the package comment.
func parseQuery(line string) (query, error) {
	fields := strings.Fields(line)
	var q query
	switch len(fields) {
	case 7:
	case 8:
		if fields[6] != "divide" {
			return q, fmt.Errorf("expected \"divide\", got %q", fields[6])
		}
		q.divide = true
	default:
		return q, fmt.Errorf("expected 7 or 8 fields, got %d", len(fields))
	}
	depth, err := strconv.Atoi(fields[len(fields)-1])
	if err != nil || depth < 0 || (q.divide && depth < 1) {
		return q, fmt.Errorf("invalid depth %q", fields[len(fields)-1])
	}
	q.depth = depth
	q.pos, err = chess.ParseFEN(strings.Join(fields[:6], " "))
	return q, err
}

// answer writes the result of the query to w.
func (q query) answer(w io.Writer) {
	if !q.divide {
		fmt.Fprintln(w, chess.Perft(q.pos, q.depth))
		return
	}
	var total uint64
	for _, e := range chess.Divide(q.pos, q.depth) {
		fmt.Fprintf(w, "%s %d\n", e.Move, e.Nodes)
		total += e.Nodes
	}
	fmt.Fprintf(w, "total %d\n", total)
}
