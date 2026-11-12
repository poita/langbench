// Command sheet reads spreadsheet commands from standard input and prints the
// results of get and dump commands to standard output.
//
// Commands, one per line:
//
//	set <CELL> <content>
//	get <CELL>
//	clear <CELL>
//	dump
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"

	"example.com/spreadsheet"
)

func main() {
	out := bufio.NewWriterSize(os.Stdout, 1<<16)
	err := run(os.Stdin, out)
	if ferr := out.Flush(); err == nil {
		err = ferr
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "sheet:", err)
		os.Exit(1)
	}
}

// run executes the commands read from in, writing output to out. Malformed
// commands are reported on standard error and skipped; the first such error is
// returned once all input has been processed.
func run(in io.Reader, out io.Writer) error {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 1<<20), 1<<28)
	s := spreadsheet.New()
	var first error
	fail := func(lineNo int, err error) {
		fmt.Fprintf(os.Stderr, "sheet: line %d: %v\n", lineNo, err)
		if first == nil {
			first = fmt.Errorf("line %d: %w", lineNo, err)
		}
	}
	for lineNo := 1; sc.Scan(); lineNo++ {
		line := sc.Text()
		cmd, rest, _ := strings.Cut(line, " ")
		switch cmd {
		case "set":
			name, content, _ := strings.Cut(rest, " ")
			if err := s.Set(name, content); err != nil {
				fail(lineNo, err)
			}
		case "get":
			v, err := s.Get(rest)
			if err != nil {
				fail(lineNo, err)
				continue
			}
			io.WriteString(out, v.String())
			io.WriteString(out, "\n")
		case "clear":
			if err := s.Clear(rest); err != nil {
				fail(lineNo, err)
			}
		case "dump":
			for _, e := range s.Dump() {
				io.WriteString(out, e.Name)
				io.WriteString(out, " ")
				io.WriteString(out, e.Value.String())
				io.WriteString(out, "\n")
			}
		default:
			fail(lineNo, fmt.Errorf("unknown command %q", cmd))
		}
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return first
}
