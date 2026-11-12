// Package batch evaluates line-oriented operation scripts, e.g.
//
//	add 3f800000 3f800000
//	sqrt 40000000
//
// and writes one 8-digit lowercase hexadecimal result per line.
package batch

import (
	"bufio"
	"fmt"
	"io"
	"strings"

	"softfloat"
)

// Run reads operations from r and writes results to w. It stops at the first
// malformed line and returns an error naming the line number.
func Run(r io.Reader, w io.Writer) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	out := bufio.NewWriterSize(w, 1<<16)
	for n := 1; sc.Scan(); n++ {
		res, err := EvalLine(sc.Text())
		if err != nil {
			out.Flush()
			return fmt.Errorf("line %d: %w", n, err)
		}
		out.WriteString(res)
		out.WriteByte('\n')
	}
	if err := sc.Err(); err != nil {
		out.Flush()
		return err
	}
	return out.Flush()
}

// EvalLine evaluates a single "<op> <a> [<b>]" line and returns the result
// as 8 lowercase hex digits.
func EvalLine(line string) (string, error) {
	line = strings.TrimSuffix(line, "\r")
	f := strings.Fields(line)
	if len(f) == 0 {
		return "", fmt.Errorf("empty line")
	}
	op, ok := softfloat.ParseOp(f[0])
	if !ok {
		return "", fmt.Errorf("unknown operation %q", f[0])
	}
	want := 3
	if op.Unary() {
		want = 2
	}
	if len(f) != want {
		return "", fmt.Errorf("%s expects %d operand(s), got %d", op, want-1, len(f)-1)
	}
	var v [2]uint32
	for i := 1; i < want; i++ {
		x, err := ParseHex(f[i])
		if err != nil {
			return "", err
		}
		v[i-1] = x
	}
	return FormatHex(softfloat.Apply(op, v[0], v[1])), nil
}

// ParseHex parses exactly 8 hexadecimal digits into a bit pattern.
func ParseHex(s string) (uint32, error) {
	if len(s) != 8 {
		return 0, fmt.Errorf("operand %q is not 8 hex digits", s)
	}
	var x uint32
	for i := 0; i < 8; i++ {
		c := s[i]
		var d uint32
		switch {
		case c >= '0' && c <= '9':
			d = uint32(c - '0')
		case c >= 'a' && c <= 'f':
			d = uint32(c-'a') + 10
		case c >= 'A' && c <= 'F':
			d = uint32(c-'A') + 10
		default:
			return 0, fmt.Errorf("operand %q has invalid hex digit %q", s, c)
		}
		x = x<<4 | d
	}
	return x, nil
}

// FormatHex renders a bit pattern as 8 lowercase hex digits.
func FormatHex(x uint32) string {
	const digits = "0123456789abcdef"
	var b [8]byte
	for i := 7; i >= 0; i-- {
		b[i] = digits[x&0xf]
		x >>= 4
	}
	return string(b[:])
}
