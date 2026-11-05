// Command bigint evaluates arbitrary-precision integer queries.
//
// It reads queries of the form "<a> <op> <b>" from standard input, one per
// line, and prints one result line per query on standard output. See README.md
// for the full contract.
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"github.com/example/bigint"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bigint:", err)
		os.Exit(1)
	}
	out := process(in)
	if _, err := os.Stdout.Write(out); err != nil {
		fmt.Fprintln(os.Stderr, "bigint:", err)
		os.Exit(1)
	}
}

// process evaluates every query in in and returns the complete output.
func process(in []byte) []byte {
	out := make([]byte, 0, len(in)/2+64)
	for len(in) > 0 {
		var line []byte
		if i := bytes.IndexByte(in, '\n'); i >= 0 {
			line, in = in[:i], in[i+1:]
		} else {
			line, in = in, nil
		}
		out = evalLine(out, line)
		out = append(out, '\n')
	}
	return out
}

// evalLine evaluates one "<a> <op> <b>" query and appends the result to out.
func evalLine(out, line []byte) []byte {
	i := bytes.IndexByte(line, ' ')
	if i < 0 {
		return append(out, "error"...)
	}
	rest := line[i+1:]
	j := bytes.IndexByte(rest, ' ')
	if j < 0 {
		return append(out, "error"...)
	}
	a, errA := bigint.ParseBytes(line[:i])
	b, errB := bigint.ParseBytes(rest[j+1:])
	if errA != nil || errB != nil {
		return append(out, "error"...)
	}
	var (
		z   *bigint.Int
		err error
	)
	switch string(rest[:j]) {
	case "+":
		z = a.Add(b)
	case "-":
		z = a.Sub(b)
	case "*":
		z = a.Mul(b)
	case "/":
		z, err = a.Quo(b)
	case "%":
		z, err = a.Rem(b)
	case "^":
		z, err = a.Exp(b)
	case "cmp":
		return append(out, fmt.Sprint(a.Cmp(b))...)
	default:
		err = bigint.ErrSyntax
	}
	if err != nil {
		return append(out, "error"...)
	}
	return z.AppendTo(out)
}
