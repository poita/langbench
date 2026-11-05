// Command regex reads patterns and subjects from standard input and prints,
// for each subject, the first match of its pattern with capture positions.
//
// Input format:
//
//	N
//	pattern_1
//	M_1
//	subject_1_1
//	...
//
// Output is one line per subject: "no", or "match START END" followed by
// "|S,E" (or "|-" if unset) for every capture group. See README.md.
package main

import (
	"fmt"
	"io"
	"os"
)

func main() {
	in, err := readAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "regex:", err)
		os.Exit(1)
	}
	if err := run(in, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "regex:", err)
		os.Exit(1)
	}
}

// readAll reads f to EOF, pre-sizing the buffer when the size is known.
func readAll(f *os.File) ([]byte, error) {
	size := 1 << 16
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
			return buf, err
		}
	}
}
