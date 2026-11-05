// Command qrcode reads QR encoding queries from standard input and prints
// the resulting module matrices as text. See README.md for the format.
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"github.com/example/qrcode/qr"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "qrcode:", err)
		os.Exit(1)
	}
	out, err := process(in)
	if _, werr := os.Stdout.Write(out); werr != nil && err == nil {
		err = werr
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "qrcode:", err)
		os.Exit(1)
	}
}

// process handles every query line in in and returns the output text.
// On error it returns the output produced so far along with the error.
func process(in []byte) ([]byte, error) {
	out := make([]byte, 0, 1<<16)
	for lineNo := 1; len(in) > 0; lineNo++ {
		var line []byte
		if i := bytes.IndexByte(in, '\n'); i >= 0 {
			line, in = in[:i], in[i+1:]
		} else {
			line, in = in, nil
		}
		if n := len(line); n > 0 && line[n-1] == '\r' {
			line = line[:n-1]
		}
		sym, err := query(line)
		if err != nil {
			return out, fmt.Errorf("line %d: %w", lineNo, err)
		}
		out = append(out, "version "...)
		out = fmt.Appendf(out, "%d mask %d\n", sym.Version, sym.Mask)
		out = sym.AppendRows(out)
		out = append(out, '\n')
	}
	return out, nil
}

// query parses "<ecl> <mask> <text>" and encodes it.
func query(line []byte) (*qr.Symbol, error) {
	parts := bytes.SplitN(line, []byte{' '}, 3)
	if len(parts) < 3 {
		return nil, fmt.Errorf("malformed query: want \"<ecl> <mask> <text>\"")
	}
	ecl, ok := qr.ParseECL(string(parts[0]))
	if !ok {
		return nil, fmt.Errorf("invalid error correction level %q", parts[0])
	}
	mask, err := qr.ParseMask(string(parts[1]))
	if err != nil {
		return nil, err
	}
	return qr.Encode(parts[2], ecl, mask)
}
