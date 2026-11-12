// Command bigint evaluates one arbitrary-precision arithmetic query per line
// of standard input and prints one result per line.
//
// Each line has the form "<a> <op> <b>" with op one of + - * / % ^ cmp.
// Division by zero and negative exponents print "error".
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/peteralexander/bigint"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "bigint:", err)
		os.Exit(1)
	}
}

// run reads all queries from r and writes one answer line per query to w.
func run(r io.Reader, w io.Writer) error {
	in, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	out := bufio.NewWriterSize(w, 1<<20)
	var buf []byte
	text := string(in)
	for len(text) > 0 {
		line := text
		if i := strings.IndexByte(text, '\n'); i >= 0 {
			line, text = text[:i], text[i+1:]
		} else {
			text = ""
		}
		line = strings.TrimSuffix(line, "\r")
		if line == "" {
			continue
		}
		buf = evalLine(buf[:0], line)
		buf = append(buf, '\n')
		if _, err := out.Write(buf); err != nil {
			return err
		}
	}
	return out.Flush()
}

// evalLine appends the answer to one query line to buf. Malformed queries and
// arithmetic errors both produce "error".
func evalLine(buf []byte, line string) []byte {
	fields := strings.Fields(line)
	if len(fields) != 3 {
		return append(buf, "error"...)
	}
	a, errA := bigint.Parse(fields[0])
	b, errB := bigint.Parse(fields[2])
	if errA != nil || errB != nil {
		return append(buf, "error"...)
	}
	var res *bigint.Int
	var err error
	switch fields[1] {
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
		res = bigint.New(int64(a.Cmp(b)))
	default:
		err = bigint.ErrSyntax
	}
	if err != nil {
		return append(buf, "error"...)
	}
	return res.Append(buf)
}
