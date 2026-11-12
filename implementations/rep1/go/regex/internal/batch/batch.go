// Package batch implements the line-oriented batch protocol used by the
// regexbt command: a list of patterns, each followed by the subjects to
// search, answered with one result line per subject.
//
// Input:
//
//	N
//	pattern_1
//	M_1
//	subject_1_1 ... subject_1_M1
//	pattern_2 ...
//
// Output: "no" for a subject without a match, otherwise
// "match <start> <end>" followed by "|<gs>,<ge>" (or "|-") for each group.
package batch

import (
	"bufio"
	"fmt"
	"io"
	"strconv"

	"example.com/regexbt"
)

// reader reads '\n'-terminated lines verbatim.
type reader struct {
	br   *bufio.Reader
	buf  []byte // used only when a line exceeds the bufio buffer
	line int
}

// next returns the next line without its terminator. The slice is valid only
// until the following call.
func (r *reader) next() ([]byte, error) {
	r.line++
	b, err := r.br.ReadSlice('\n')
	if err == bufio.ErrBufferFull {
		r.buf = append(r.buf[:0], b...)
		for err == bufio.ErrBufferFull {
			b, err = r.br.ReadSlice('\n')
			r.buf = append(r.buf, b...)
		}
		b = r.buf
	}
	if err == io.EOF && len(b) > 0 {
		err = nil // tolerate a missing final newline
	}
	if err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		return nil, fmt.Errorf("line %d: %w", r.line, err)
	}
	if n := len(b); n > 0 && b[n-1] == '\n' {
		b = b[:n-1]
	}
	return b, nil
}

func (r *reader) nextInt() (int, error) {
	b, err := r.next()
	if err != nil {
		return 0, err
	}
	n, err := strconv.Atoi(string(b))
	if err != nil || n < 0 {
		return 0, fmt.Errorf("line %d: expected a non-negative integer, got %q", r.line, b)
	}
	return n, nil
}

// AppendResult appends the output line for a match result (without the
// trailing newline) to dst.
func AppendResult(dst []byte, m *regexbt.Match, ok bool) []byte {
	if !ok {
		return append(dst, "no"...)
	}
	dst = append(dst, "match "...)
	dst = strconv.AppendInt(dst, int64(m.Start), 10)
	dst = append(dst, ' ')
	dst = strconv.AppendInt(dst, int64(m.End), 10)
	for _, g := range m.Groups {
		dst = append(dst, '|')
		if g.IsSet() {
			dst = strconv.AppendInt(dst, int64(g.Start), 10)
			dst = append(dst, ',')
			dst = strconv.AppendInt(dst, int64(g.End), 10)
		} else {
			dst = append(dst, '-')
		}
	}
	return dst
}

// Run processes a whole batch from in and writes the results to out. Output
// produced before an error is still flushed.
func Run(in io.Reader, out io.Writer) error {
	r := &reader{br: bufio.NewReaderSize(in, 1<<20)}
	w := bufio.NewWriterSize(out, 1<<20)
	err := run(r, w)
	if ferr := w.Flush(); err == nil {
		err = ferr
	}
	return err
}

func run(r *reader, w *bufio.Writer) error {
	n, err := r.nextInt()
	if err != nil {
		return err
	}
	var (
		m   regexbt.Match
		out []byte
	)
	for ; n > 0; n-- {
		patBytes, err := r.next()
		if err != nil {
			return err
		}
		pat := string(patBytes) // copy: the next read invalidates patBytes
		patLine := r.line
		count, err := r.nextInt()
		if err != nil {
			return err
		}
		re, err := regexbt.Compile(pat)
		if err != nil {
			return fmt.Errorf("line %d: %w", patLine, err)
		}
		for ; count > 0; count-- {
			subj, err := r.next()
			if err != nil {
				return err
			}
			ok := re.FindInto(string(subj), &m)
			out = AppendResult(out[:0], &m, ok)
			out = append(out, '\n')
			if _, err := w.Write(out); err != nil {
				return err
			}
		}
	}
	return nil
}
