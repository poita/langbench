// Package batch implements the line-oriented text protocol of the softfloat
// command: one operation per input line, one 8-digit hex result per output
// line.
package batch

import (
	"fmt"

	"softfloat"
)

const hexDigits = "0123456789abcdef"

// hexVal maps an ASCII byte to its hex value, or 0xff if it is not a
// lowercase or uppercase hex digit.
var hexVal = func() (t [256]byte) {
	for i := range t {
		t[i] = 0xff
	}
	for i := 0; i < 10; i++ {
		t['0'+i] = byte(i)
	}
	for i := 0; i < 6; i++ {
		t['a'+i] = byte(10 + i)
		t['A'+i] = byte(10 + i)
	}
	return
}()

// parseHex8 decodes exactly eight hex digits from the start of p.
func parseHex8(p []byte) (uint32, bool) {
	if len(p) < 8 {
		return 0, false
	}
	var v uint32
	for _, c := range p[:8] {
		d := hexVal[c]
		if d == 0xff {
			return 0, false
		}
		v = v<<4 | uint32(d)
	}
	return v, true
}

// parseOp recognises the operation mnemonic at the start of line and returns
// it along with the number of bytes consumed (mnemonic plus one space).
func parseOp(line []byte) (softfloat.Op, int, bool) {
	if len(line) < 4 {
		return 0, 0, false
	}
	var op softfloat.Op
	n := 4
	switch string(line[:4]) {
	case "add ":
		op = softfloat.OpAdd
	case "sub ":
		op = softfloat.OpSub
	case "mul ":
		op = softfloat.OpMul
	case "div ":
		op = softfloat.OpDiv
	case "sqrt":
		if len(line) < 5 || line[4] != ' ' {
			return 0, 0, false
		}
		op, n = softfloat.OpSqrt, 5
	default:
		return 0, 0, false
	}
	return op, n, true
}

// ParseLine decodes one input line (without its terminator) into an
// operation and its operands. For unary operations b is zero.
func ParseLine(line []byte) (op softfloat.Op, a, b uint32, err error) {
	op, n, ok := parseOp(line)
	if !ok {
		return 0, 0, 0, fmt.Errorf("unknown operation in %q", line)
	}
	if a, ok = parseHex8(line[n:]); !ok {
		return 0, 0, 0, fmt.Errorf("bad first operand in %q", line)
	}
	n += 8
	if op.Unary() {
		if len(line) != n {
			return 0, 0, 0, fmt.Errorf("trailing data in %q", line)
		}
		return op, a, 0, nil
	}
	if len(line) != n+9 || line[n] != ' ' {
		return 0, 0, 0, fmt.Errorf("malformed binary operation %q", line)
	}
	if b, ok = parseHex8(line[n+1:]); !ok {
		return 0, 0, 0, fmt.Errorf("bad second operand in %q", line)
	}
	return op, a, b, nil
}

// AppendHex8 appends v as eight lowercase hex digits followed by a newline.
func AppendHex8(dst []byte, v uint32) []byte {
	return append(dst,
		hexDigits[v>>28], hexDigits[v>>24&15], hexDigits[v>>20&15], hexDigits[v>>16&15],
		hexDigits[v>>12&15], hexDigits[v>>8&15], hexDigits[v>>4&15], hexDigits[v&15], '\n')
}

// Process evaluates every line of in and returns the concatenated results,
// one per line. A final line without a newline, and a stray '\r' before a
// newline, are accepted. It returns an error naming the first malformed line.
func Process(in []byte) ([]byte, error) {
	out := make([]byte, 0, 9*(len(in)/13+1))
	lineNo := 0
	for i := 0; i < len(in); {
		j := i
		for j < len(in) && in[j] != '\n' {
			j++
		}
		line := in[i:j]
		i = j + 1
		lineNo++
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		if len(line) == 0 {
			continue // tolerate blank lines
		}
		op, a, b, err := ParseLine(line)
		if err != nil {
			return out, fmt.Errorf("line %d: %w", lineNo, err)
		}
		out = AppendHex8(out, softfloat.Eval(op, a, b))
	}
	return out, nil
}
