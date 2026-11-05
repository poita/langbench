// Package lines implements the line model used throughout the parser: a line
// ends at LF, and a single CR directly before the LF belongs to the
// terminator. Normalising a message turns every CRLF into LF and changes
// nothing else.
package lines

import "bytes"

// NormalizeCRLF returns b with every CRLF replaced by LF. A CR that is not
// directly followed by LF is kept. The result is a fresh buffer sized to the
// input; b is not modified.
func NormalizeCRLF(b []byte) []byte {
	out := make([]byte, 0, len(b))
	for {
		i := bytes.IndexByte(b, '\r')
		if i < 0 {
			return append(out, b...)
		}
		if i+1 < len(b) && b[i+1] == '\n' {
			out = append(out, b[:i]...)
			b = b[i+1:] // keep the LF
			continue
		}
		out = append(out, b[:i+1]...)
		b = b[i+1:]
	}
}

// Next returns the first line of b without its terminator and the number of
// bytes the line plus its terminator occupy. ok is false when b is empty.
func Next(b []byte) (line []byte, size int, ok bool) {
	if len(b) == 0 {
		return nil, 0, false
	}
	i := bytes.IndexByte(b, '\n')
	if i < 0 {
		line, size = b, len(b)
	} else {
		line, size = b[:i], i+1
	}
	if i >= 0 && len(line) > 0 && line[len(line)-1] == '\r' {
		line = line[:len(line)-1]
	}
	return line, size, true
}
