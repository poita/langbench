package main

import (
	"bytes"

	"github.com/peteralexander/bigint"
)

// Process evaluates every query line in input and returns all the output
// lines in one buffer. Queries that fail (division by zero, negative
// exponent, or malformed input) produce the line "error".
func Process(input []byte) []byte {
	out := make([]byte, 0, len(input)/2+64)
	for len(input) > 0 {
		var line []byte
		if i := bytes.IndexByte(input, '\n'); i >= 0 {
			line, input = input[:i], input[i+1:]
		} else {
			line, input = input, nil
		}
		out = evalLine(out, line)
		out = append(out, '\n')
	}
	return out
}

// evalLine evaluates one "<a> <op> <b>" query and appends the result.
func evalLine(out, line []byte) []byte {
	sp1 := bytes.IndexByte(line, ' ')
	sp2 := bytes.LastIndexByte(line, ' ')
	if sp1 < 0 || sp2 <= sp1 {
		return append(out, "error"...)
	}
	op := string(line[sp1+1 : sp2])
	a, errA := bigint.ParseBytes(line[:sp1])
	b, errB := bigint.ParseBytes(line[sp2+1:])
	if errA != nil || errB != nil {
		return append(out, "error"...)
	}

	var (
		r   bigint.Int
		err error
	)
	switch op {
	case "+":
		r = a.Add(b)
	case "-":
		r = a.Sub(b)
	case "*":
		r = a.Mul(b)
	case "/":
		r, err = a.Quo(b)
	case "%":
		r, err = a.Rem(b)
	case "^":
		r, err = a.Pow(b)
	case "cmp":
		r = bigint.FromInt64(int64(a.Cmp(b)))
	default:
		err = bigint.ErrSyntax
	}
	if err != nil {
		return append(out, "error"...)
	}
	return r.AppendTo(out)
}
