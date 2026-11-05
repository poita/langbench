// Command inflate reads a hex-encoded raw DEFLATE stream on standard input
// and writes the decompressed bytes as hex on standard output, or the word
// "error" if the stream is malformed.
//
// Usage:
//
//	echo 4b4c4a862000 | inflate
package main

import (
	"bytes"
	"encoding/hex"
	"io"
	"os"

	"example.com/inflate"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		os.Stderr.WriteString("inflate: " + err.Error() + "\n")
		os.Exit(1)
	}
}

// run implements the command: it reads all of in, decodes it and writes
// exactly one line to out. Malformed streams are reported as "error" on out
// and are not a failure of run; only I/O problems are returned.
func run(in io.Reader, out io.Writer) error {
	text, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	text = bytes.TrimSpace(text)

	// Bad hex is outside the input contract; treat it as a malformed stream.
	src := make([]byte, len(text)/2)
	if _, herr := hex.Decode(src, text); herr != nil {
		return writeAll(out, []byte("error\n"))
	}
	res, derr := inflate.Decode(src)
	if derr != nil {
		return writeAll(out, []byte("error\n"))
	}

	// Encode into one buffer of 2*len+1 bytes and write it in one call.
	line := make([]byte, 2*len(res)+1)
	hex.Encode(line, res)
	line[len(line)-1] = '\n'
	return writeAll(out, line)
}

func writeAll(w io.Writer, b []byte) error {
	_, err := w.Write(b)
	return err
}
