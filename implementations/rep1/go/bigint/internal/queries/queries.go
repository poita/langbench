// Package queries implements the line-oriented query language of the bigint
// command: "<a> <op> <b>" per line.
package queries

import (
	"bytes"

	"github.com/example/bigint"
)

// Process evaluates every query in in and appends one result line per query
// to out, returning the extended buffer. A trailing newline on the final
// query is optional; empty input produces no output. Blank lines are skipped.
func Process(in, out []byte) []byte {
	for len(in) > 0 {
		var line []byte
		if i := bytes.IndexByte(in, '\n'); i >= 0 {
			line, in = in[:i], in[i+1:]
		} else {
			line, in = in, nil
		}
		if len(line) == 0 {
			continue
		}
		out = Eval(line, out)
		out = append(out, '\n')
	}
	return out
}

// Eval evaluates a single query line (without its newline) and appends the
// result (without a newline) to out. Malformed lines produce "error".
func Eval(line, out []byte) []byte {
	i := bytes.IndexByte(line, ' ')
	if i < 0 {
		return append(out, "error"...)
	}
	rest := line[i+1:]
	j := bytes.IndexByte(rest, ' ')
	if j < 0 {
		return append(out, "error"...)
	}
	aTok, op, bTok := line[:i], rest[:j], rest[j+1:]

	a, err := bigint.ParseBytes(aTok)
	if err != nil {
		return append(out, "error"...)
	}
	b, err := bigint.ParseBytes(bTok)
	if err != nil {
		return append(out, "error"...)
	}

	var res *bigint.Int
	switch string(op) {
	case "+":
		res = a.Add(b)
	case "-":
		res = a.Sub(b)
	case "*":
		res = a.Mul(b)
	case "/":
		res, err = a.Div(b)
	case "%":
		res, err = a.Rem(b)
	case "^":
		res, err = a.Exp(b)
	case "cmp":
		switch a.Cmp(b) {
		case -1:
			return append(out, "-1"...)
		case 0:
			return append(out, '0')
		}
		return append(out, '1')
	default:
		err = bigint.ErrDivideByZero // unknown operator
	}
	if err != nil {
		return append(out, "error"...)
	}
	return res.AppendTo(out)
}
