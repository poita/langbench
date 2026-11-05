// Command chess-perft answers perft and divide queries read from standard
// input, one per line, and writes one result per query to standard output.
//
// A query is a FEN record followed by either a depth or "divide" and a depth:
//
//	<placement> <side> <castling> <ep> <halfmove> <fullmove> <depth>
//	<placement> <side> <castling> <ep> <halfmove> <fullmove> divide <depth>
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"chessperft/chess"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "chess-perft:", err)
		os.Exit(1)
	}
}

// run reads every query from r and writes the results to w.
func run(r io.Reader, w io.Writer) error {
	in := bufio.NewReaderSize(r, 1<<16)
	out := bufio.NewWriterSize(w, 1<<16)
	for {
		line, err := in.ReadString('\n')
		line = strings.TrimSpace(line)
		if line != "" {
			if qerr := answer(out, line); qerr != nil {
				return qerr
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
	}
	return out.Flush()
}

// answer evaluates one query line and writes its result.
func answer(w *bufio.Writer, line string) error {
	f := strings.Split(line, " ")
	if len(f) != 7 && len(f) != 8 {
		return fmt.Errorf("malformed query %q", line)
	}
	divide := len(f) == 8
	if divide && f[6] != "divide" {
		return fmt.Errorf("malformed query %q", line)
	}
	depth, err := strconv.Atoi(f[len(f)-1])
	if err != nil || depth < 0 {
		return fmt.Errorf("bad depth in query %q", line)
	}
	pos, err := chess.ParseFEN(strings.Join(f[:6], " "))
	if err != nil {
		return err
	}
	if !divide {
		w.WriteString(strconv.FormatUint(pos.Perft(depth), 10))
		w.WriteByte('\n')
		return nil
	}
	var total uint64
	for _, e := range pos.Divide(depth) {
		w.WriteString(e.Move.String())
		w.WriteByte(' ')
		w.WriteString(strconv.FormatUint(e.Count, 10))
		w.WriteByte('\n')
		total += e.Count
	}
	w.WriteString("total ")
	w.WriteString(strconv.FormatUint(total, 10))
	w.WriteByte('\n')
	return nil
}
