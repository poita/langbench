// Command jsoncanon reads one JSON document from standard input and prints
// its canonical serialization, or the line "invalid" if it is not a valid
// document. The exit status is 0 in both cases.
package main

import (
	"io"
	"os"

	"example.com/jsoncanon"
)

func main() {
	src, err := readAll(os.Stdin)
	if err != nil {
		os.Stderr.WriteString("jsoncanon: " + err.Error() + "\n")
		os.Exit(1)
	}
	out, err := jsoncanon.Canonicalize(src)
	if err != nil {
		out = []byte("invalid")
	}
	out = append(out, '\n')
	if _, err := os.Stdout.Write(out); err != nil {
		os.Exit(1)
	}
}

// readAll reads f to EOF, presizing the buffer when the size is known.
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
			return nil, err
		}
	}
}
