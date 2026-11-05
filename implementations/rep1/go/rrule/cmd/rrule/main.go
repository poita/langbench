// Command rrule reads recurrence rules from standard input, one per line in
// the form "<DTSTART> <RRULE> <N>", and prints the first N occurrences of
// each rule on one line.
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"github.com/example/rrule"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "rrule:", err)
		os.Exit(1)
	}
	out, err := process(in)
	if _, werr := os.Stdout.Write(out); werr != nil && err == nil {
		err = werr
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "rrule:", err)
		os.Exit(1)
	}
}

// process expands every line of in and returns the output. On a malformed
// line it returns the output produced so far together with the error.
func process(in []byte) ([]byte, error) {
	out := make([]byte, 0, 1<<16)
	exp := rrule.NewExpander()
	for lineNo := 1; len(in) > 0; lineNo++ {
		var line []byte
		if i := bytes.IndexByte(in, '\n'); i >= 0 {
			line, in = in[:i], in[i+1:]
		} else {
			line, in = in, nil
		}
		var err error
		if out, err = expandLine(out, exp, line); err != nil {
			return out, fmt.Errorf("line %d: %w", lineNo, err)
		}
	}
	return out, nil
}

// expandLine parses one "<DTSTART> <RRULE> <N>" line and appends the
// occurrences and a newline to out.
func expandLine(out []byte, exp *rrule.Expander, line []byte) ([]byte, error) {
	i := bytes.IndexByte(line, ' ')
	j := bytes.LastIndexByte(line, ' ')
	if i < 0 || j <= i {
		return out, fmt.Errorf("expected \"<DTSTART> <RRULE> <N>\"")
	}
	start, err := rrule.ParseDateTime(string(line[:i]))
	if err != nil {
		return out, err
	}
	rule, err := rrule.ParseRule(string(line[i+1 : j]))
	if err != nil {
		return out, err
	}
	n := 0
	for _, c := range line[j+1:] {
		if c < '0' || c > '9' || n > 1e9 {
			return out, fmt.Errorf("bad limit %q", line[j+1:])
		}
		n = n*10 + int(c-'0')
	}
	if out, err = exp.AppendText(out, rule, start, n); err != nil {
		return out, err
	}
	return append(out, '\n'), nil
}
