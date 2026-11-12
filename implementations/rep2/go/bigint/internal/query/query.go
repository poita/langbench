// Package query evaluates the line-oriented "<a> <op> <b>" query language
// used by the bigint command-line tool.
package query

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strings"

	"example.com/bigint"
)

// ErrorLine is printed in place of a result when a query is an arithmetic
// error (division by zero, negative exponent).
const ErrorLine = "error"

// maxLine bounds the size of a single input line.
const maxLine = 1 << 20

// Eval evaluates one query line and returns its output line (without the
// trailing newline). Arithmetic errors yield ErrorLine and a nil error; a
// malformed query yields a non-nil error.
func Eval(line string) (string, error) {
	f := strings.Split(line, " ")
	if len(f) != 3 {
		return "", fmt.Errorf("query %q: want \"<a> <op> <b>\"", abbrev(line))
	}
	a, err := bigint.Parse(f[0])
	if err != nil {
		return "", fmt.Errorf("query %q: left operand: %w", abbrev(line), err)
	}
	b, err := bigint.Parse(f[2])
	if err != nil {
		return "", fmt.Errorf("query %q: right operand: %w", abbrev(line), err)
	}

	var res *bigint.Int
	switch f[1] {
	case "+":
		res = a.Add(b)
	case "-":
		res = a.Sub(b)
	case "*":
		res = a.Mul(b)
	case "/":
		res, err = a.Quo(b)
	case "%":
		res, err = a.Rem(b)
	case "^":
		res, err = a.Exp(b)
	case "cmp":
		return fmt.Sprint(a.Cmp(b)), nil
	default:
		return "", fmt.Errorf("query %q: unknown operator %q", abbrev(line), f[1])
	}
	if err != nil {
		if errors.Is(err, bigint.ErrDivByZero) || errors.Is(err, bigint.ErrNegativeExponent) {
			return ErrorLine, nil
		}
		return "", err
	}
	return res.String(), nil
}

func abbrev(s string) string {
	if len(s) > 40 {
		return s[:40] + "..."
	}
	return s
}

// Run reads queries from r, one per line, and writes one result line per
// query to w. A final line without a trailing newline is accepted.
func Run(r io.Reader, w io.Writer) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), maxLine)
	out := bufio.NewWriterSize(w, 1<<16)
	for sc.Scan() {
		res, err := Eval(sc.Text())
		if err != nil {
			out.Flush()
			return err
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
