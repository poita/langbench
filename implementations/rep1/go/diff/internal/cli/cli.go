// Package cli implements the command-line input/output contract: a mode line
// ("diff" or "patch") followed by counted blocks of lines on standard input,
// and counted output on standard output.
package cli

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"

	"example.com/diff"
)

// Run reads a request from r and writes the response to w.
func Run(r io.Reader, w io.Writer) error {
	data, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	in := &reader{s: string(data)}
	mode, err := in.line()
	if err != nil {
		return fmt.Errorf("mode: %w", err)
	}
	mode = strings.TrimRight(mode, " \t")
	bw := bufio.NewWriterSize(w, 1<<16)
	switch mode {
	case "diff":
		err = runDiff(in, bw)
	case "patch":
		err = runPatch(in, bw)
	default:
		err = fmt.Errorf("unknown mode %q", mode)
	}
	if err != nil {
		return err
	}
	return bw.Flush()
}

func runDiff(in *reader, w *bufio.Writer) error {
	a, err := in.block("A")
	if err != nil {
		return err
	}
	b, err := in.block("B")
	if err != nil {
		return err
	}
	return writeBlock(w, diff.Diff(a, b))
}

func runPatch(in *reader, w *bufio.Writer) error {
	a, err := in.block("A")
	if err != nil {
		return err
	}
	lines, err := in.block("script")
	if err != nil {
		return err
	}
	script, err := diff.ParseScript(lines)
	if err != nil {
		return err
	}
	out, err := diff.Apply(a, script)
	if err != nil {
		return err
	}
	w.WriteString(strconv.Itoa(len(out)))
	w.WriteByte('\n')
	for _, l := range out {
		w.WriteString(l)
		w.WriteByte('\n')
	}
	return nil
}

func writeBlock(w *bufio.Writer, s diff.Script) error {
	w.WriteString(strconv.Itoa(len(s)))
	w.WriteByte('\n')
	for _, e := range s {
		w.WriteByte(e.Op.Tag())
		w.WriteString(e.Line)
		w.WriteByte('\n')
	}
	return nil
}

// reader splits the input into lines without copying.
type reader struct {
	s   string
	pos int
}

func (r *reader) line() (string, error) {
	if r.pos >= len(r.s) {
		return "", io.ErrUnexpectedEOF
	}
	rest := r.s[r.pos:]
	i := strings.IndexByte(rest, '\n')
	if i < 0 { // missing final newline
		r.pos = len(r.s)
		return rest, nil
	}
	r.pos += i + 1
	return rest[:i], nil
}

// block reads a count line followed by that many lines.
func (r *reader) block(name string) ([]string, error) {
	cl, err := r.line()
	if err != nil {
		return nil, fmt.Errorf("%s count: %w", name, err)
	}
	cl = strings.TrimRight(cl, " \t")
	n, err := strconv.Atoi(cl)
	if err != nil || n < 0 {
		return nil, fmt.Errorf("%s count: invalid %q", name, cl)
	}
	// Each line takes at least one byte of input.
	if n > len(r.s)-r.pos+1 {
		return nil, fmt.Errorf("%s: count %d exceeds input", name, n)
	}
	lines := make([]string, n)
	for i := range lines {
		l, err := r.line()
		if err != nil {
			return nil, fmt.Errorf("%s line %d: %w", name, i+1, err)
		}
		lines[i] = l
	}
	return lines, nil
}
