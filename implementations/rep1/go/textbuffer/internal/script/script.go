// Package script interprets the textbuffer command language: a document
// followed by a sequence of editing commands, with "print" commands producing
// output. It is the I/O layer behind the command-line tool.
//
// The input is: a line holding the number N of document lines, N document
// lines taken verbatim, then one command per line until end of input.
package script

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"

	"textbuffer"
)

// Run reads a complete script from r, executes it, and writes the output of
// its print commands to w. Output produced before an error is still written.
func Run(r io.Reader, w io.Writer) error {
	data, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	out := bufio.NewWriterSize(w, 1<<16)
	runErr := RunString(string(data), out)
	if err := out.Flush(); err != nil && runErr == nil {
		runErr = err
	}
	return runErr
}

// RunString is like Run but takes the script as a string and writes to w
// without flushing it.
func RunString(input string, w io.Writer) error {
	lines := &lineReader{s: input}
	header, ok := lines.next()
	if !ok {
		return fmt.Errorf("line 1: missing document line count")
	}
	n, err := strconv.Atoi(strings.TrimSpace(header))
	if err != nil || n < 0 {
		return fmt.Errorf("line 1: invalid document line count %q", header)
	}
	doc := make([]string, 0, n)
	for i := 0; i < n; i++ {
		l, _ := lines.next() // a missing line counts as empty
		doc = append(doc, l)
	}
	in := New(textbuffer.NewFromLines(doc), w)
	for {
		cmd, ok := lines.next()
		if !ok {
			return nil
		}
		if err := in.Exec(cmd); err != nil {
			return fmt.Errorf("line %d: %w", lines.n, err)
		}
	}
}

// lineReader splits a string at '\n' without copying; a final newline does
// not start another line.
type lineReader struct {
	s string
	n int // number of lines returned so far
}

func (r *lineReader) next() (string, bool) {
	if r.s == "" {
		return "", false
	}
	r.n++
	i := strings.IndexByte(r.s, '\n')
	if i < 0 {
		l := r.s
		r.s = ""
		return l, true
	}
	l := r.s[:i]
	r.s = r.s[i+1:]
	return l, true
}

// Interpreter executes commands against a buffer.
type Interpreter struct {
	buf *textbuffer.Buffer
	out io.Writer
}

// New returns an interpreter that edits buf and writes print output to w.
func New(buf *textbuffer.Buffer, w io.Writer) *Interpreter {
	return &Interpreter{buf: buf, out: w}
}

// Buffer returns the buffer being edited.
func (in *Interpreter) Buffer() *textbuffer.Buffer { return in.buf }

// Exec executes one command line. Blank lines are ignored.
func (in *Interpreter) Exec(line string) error {
	if line == "" {
		return nil
	}
	word, rest, hasArgs := strings.Cut(line, " ")
	b := in.buf
	switch word {
	case "insert":
		if !hasArgs || rest == "" {
			return fmt.Errorf("insert: missing text")
		}
		text, err := DecodeInsert(rest)
		if err != nil {
			return fmt.Errorf("insert: %w", err)
		}
		b.Insert(text)
	case "delete":
		return noArgs(word, hasArgs, func() { b.Delete() })
	case "delete-forward":
		return noArgs(word, hasArgs, func() { b.DeleteForward() })
	case "undo":
		return noArgs(word, hasArgs, func() { b.Undo() })
	case "redo":
		return noArgs(word, hasArgs, func() { b.Redo() })
	case "clear-cursors":
		return noArgs(word, hasArgs, b.ClearCursors)
	case "print":
		if hasArgs {
			return fmt.Errorf("print: unexpected arguments")
		}
		return in.print()
	case "move":
		dirName, flag, hasFlag := strings.Cut(rest, " ")
		dir, err := textbuffer.ParseDirection(dirName)
		if err != nil || !hasArgs {
			return fmt.Errorf("move: invalid direction %q", dirName)
		}
		if hasFlag && flag != "select" {
			return fmt.Errorf("move: unexpected argument %q", flag)
		}
		b.Move(dir, hasFlag)
	case "goto", "add-cursor":
		l, c, err := parsePair(rest)
		if err != nil || !hasArgs {
			return fmt.Errorf("%s: expected <line> <col>", word)
		}
		if word == "goto" {
			b.GoTo(l, c)
		} else {
			b.AddCursor(l, c)
		}
	default:
		return fmt.Errorf("unknown command %q", word)
	}
	return nil
}

func noArgs(name string, hasArgs bool, f func()) error {
	if hasArgs {
		return fmt.Errorf("%s: unexpected arguments", name)
	}
	f()
	return nil
}

func parsePair(s string) (int, int, error) {
	a, b, ok := strings.Cut(s, " ")
	if !ok {
		return 0, 0, fmt.Errorf("want two integers")
	}
	x, err := strconv.Atoi(a)
	if err != nil {
		return 0, 0, err
	}
	y, err := strconv.Atoi(b)
	if err != nil {
		return 0, 0, err
	}
	return x, y, nil
}

// print writes every document line followed by '\n', then one
// "cursor <line> <col>" line per cursor, then "--".
func (in *Interpreter) print() error {
	if _, err := in.buf.WriteTo(in.out); err != nil {
		return err
	}
	if _, err := io.WriteString(in.out, "\n"); err != nil {
		return err
	}
	var num [48]byte
	for _, c := range in.buf.Cursors() {
		p := append(num[:0], "cursor "...)
		p = strconv.AppendInt(p, int64(c.Head.Line), 10)
		p = append(p, ' ')
		p = strconv.AppendInt(p, int64(c.Head.Col), 10)
		p = append(p, '\n')
		if _, err := in.out.Write(p); err != nil {
			return err
		}
	}
	_, err := io.WriteString(in.out, "--\n")
	return err
}

// DecodeInsert decodes the argument of an insert command: "\n" becomes a
// newline and "\\" a single backslash. Any other use of a backslash is an
// error.
func DecodeInsert(s string) (string, error) {
	if !strings.Contains(s, "\\") {
		return s, nil
	}
	var sb strings.Builder
	sb.Grow(len(s))
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' {
			sb.WriteByte(s[i])
			continue
		}
		i++
		if i == len(s) {
			return "", fmt.Errorf("dangling backslash")
		}
		switch s[i] {
		case 'n':
			sb.WriteByte('\n')
		case '\\':
			sb.WriteByte('\\')
		default:
			return "", fmt.Errorf("invalid escape \\%c", s[i])
		}
	}
	return sb.String(), nil
}
