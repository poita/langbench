// Command inflate reads a hex-encoded raw DEFLATE stream on stdin and writes
// the decompressed bytes as hex on stdout, or the word "error" if the stream
// is malformed. It always exits with status 0 unless I/O itself fails.
package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"io"
	"os"

	"example.com/inflate"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "inflate:", err)
		os.Exit(1)
	}
}

// run implements the command: stdin hex -> stdout hex or "error".
func run(in io.Reader, out io.Writer) error {
	text, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	src := make([]byte, hex.DecodedLen(len(bytes.TrimSpace(text))))
	if _, err := hex.Decode(src, bytes.TrimSpace(text)); err != nil {
		_, err = io.WriteString(out, "error\n")
		return err
	}
	data, err := inflate.Decode(src)
	if err != nil {
		_, err = io.WriteString(out, "error\n")
		return err
	}
	line := make([]byte, hex.EncodedLen(len(data))+1)
	hex.Encode(line, data)
	line[len(line)-1] = '\n'
	_, err = out.Write(line)
	return err
}
