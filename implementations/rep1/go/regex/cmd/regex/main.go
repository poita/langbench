// Command regex reads patterns and subjects from standard input and prints,
// for each subject, the first match and its capture-group positions.
//
// Input: N, then for each pattern a line with the pattern, a line with the
// subject count M, and M subject lines. Output: one line per subject, either
// "no" or "match <start> <end>" followed by "|<gs>,<ge>" or "|-" per group.
package main

import (
	"fmt"
	"io"
	"os"

	"example.com/regex/internal/batch"
)

func main() {
	input, err := readAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "regex:", err)
		os.Exit(1)
	}
	if err := batch.Run(input, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "regex:", err)
		os.Exit(1)
	}
}

// readAll reads f in one go, sizing the buffer from the file size if known.
func readAll(f *os.File) ([]byte, error) {
	size := 1 << 20
	if st, err := f.Stat(); err == nil && st.Mode().IsRegular() && st.Size() > 0 {
		size = int(st.Size()) + 1
	}
	buf := make([]byte, 0, size)
	for {
		if len(buf) == cap(buf) {
			buf = append(buf, 0)[:len(buf)]
		}
		n, err := f.Read(buf[len(buf):cap(buf)])
		buf = buf[:len(buf)+n]
		if err == io.EOF {
			return buf, nil
		}
		if err != nil {
			return nil, err
		}
	}
}
