// Command qrcode reads query lines "<ecl> <mask> <text>" from standard input
// and prints the corresponding QR Code symbols as text.
//
// For each query it prints "version <v> mask <m>", the symbol rows using '#'
// for dark and '.' for light modules, and an empty line.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"

	"github.com/peteralexander/qrcode"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "qrcode:", err)
		os.Exit(1)
	}
}

// run processes every query line of in, writing the results to out.
func run(in io.Reader, out io.Writer) error {
	r := bufio.NewReaderSize(in, 1<<16)
	w := bufio.NewWriterSize(out, 1<<16)
	defer w.Flush()
	for lineNo := 1; ; lineNo++ {
		line, err := r.ReadString('\n')
		if err != nil && err != io.EOF {
			return err
		}
		eof := err == io.EOF
		if len(line) > 0 && line[len(line)-1] == '\n' {
			line = line[:len(line)-1]
		}
		if line != "" || !eof {
			if line == "" {
				return fmt.Errorf("line %d: empty query", lineNo)
			}
			if err := query(w, line); err != nil {
				return fmt.Errorf("line %d: %w", lineNo, err)
			}
		}
		if eof {
			return w.Flush()
		}
	}
}

// parseQuery splits "<ecl> <mask> <text>".
func parseQuery(line string) (level qrcode.Level, mask int, text string, err error) {
	if len(line) < 5 || line[1] != ' ' {
		return 0, 0, "", fmt.Errorf("malformed query %q", line)
	}
	switch line[0] {
	case 'L':
		level = qrcode.L
	case 'M':
		level = qrcode.M
	case 'Q':
		level = qrcode.Q
	case 'H':
		level = qrcode.H
	default:
		return 0, 0, "", fmt.Errorf("invalid error-correction level %q", line[:1])
	}
	rest := line[2:]
	sp := 0
	for sp < len(rest) && rest[sp] != ' ' {
		sp++
	}
	if sp == len(rest) {
		return 0, 0, "", fmt.Errorf("missing text in query")
	}
	if word := rest[:sp]; word == "auto" {
		mask = qrcode.AutoMask
	} else if m, e := strconv.Atoi(word); e == nil && len(word) == 1 && m >= 0 && m < qrcode.NumMasks {
		mask = m
	} else {
		return 0, 0, "", fmt.Errorf("invalid mask %q", word)
	}
	return level, mask, rest[sp+1:], nil
}

func query(w io.Writer, line string) error {
	level, mask, text, err := parseQuery(line)
	if err != nil {
		return err
	}
	sym, err := qrcode.Encode(text, level, mask)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "version %d mask %d\n%s\n", sym.Version(), sym.Mask(), sym.String())
	return err
}
