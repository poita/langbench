// Command rrule reads lines of the form "<DTSTART> <RRULE> <N>" on standard
// input and prints, for each, the first N occurrences of the rule.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/example/rrule"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "rrule:", err)
		os.Exit(1)
	}
}

// run processes every line of in and writes one output line per input line.
func run(in io.Reader, out io.Writer) error {
	r := bufio.NewReaderSize(in, 1<<20)
	w := bufio.NewWriterSize(out, 1<<20)
	var buf []byte
	for lineNo := 1; ; lineNo++ {
		line, err := r.ReadString('\n')
		if err != nil && err != io.EOF {
			return err
		}
		if line != "" {
			line = strings.TrimSuffix(line, "\n")
			var perr error
			buf, perr = processLine(buf[:0], line)
			if perr != nil {
				return fmt.Errorf("line %d: %w", lineNo, perr)
			}
			buf = append(buf, '\n')
			if _, werr := w.Write(buf); werr != nil {
				return werr
			}
		}
		if err == io.EOF {
			break
		}
	}
	return w.Flush()
}

// processLine appends the output for one input line (without the newline).
func processLine(buf []byte, line string) ([]byte, error) {
	fields := strings.Split(line, " ")
	if len(fields) != 3 {
		return buf, fmt.Errorf("expected \"<DTSTART> <RRULE> <N>\", got %q", line)
	}
	start, err := rrule.ParseDateTime(fields[0])
	if err != nil {
		return buf, err
	}
	rule, err := rrule.ParseRule(fields[1])
	if err != nil {
		return buf, err
	}
	n, err := strconv.Atoi(fields[2])
	if err != nil || n < 1 {
		return buf, fmt.Errorf("invalid N %q", fields[2])
	}
	first := true
	err = rule.Each(start, n, func(t rrule.DateTime) bool {
		if !first {
			buf = append(buf, ' ')
		}
		first = false
		buf = t.AppendFormat(buf)
		return true
	})
	return buf, err
}
