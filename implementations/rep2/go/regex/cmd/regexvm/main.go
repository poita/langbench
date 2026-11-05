// Command regexvm reads regex patterns and subject lines from stdin and
// reports, for each subject, the first match and its capture positions.
//
// Input: N, then N blocks of (pattern line, M, M subject lines).
// Output: one line per subject, "no" or "match S E|gs,ge|-|...".
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"example.com/regexvm"
)

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "regexvm:", err)
		os.Exit(1)
	}
}

// lines is a cursor over newline-terminated lines of a byte buffer.
type lines struct {
	buf []byte
	pos int
}

func (l *lines) next() ([]byte, bool) {
	if l.pos >= len(l.buf) {
		return nil, false
	}
	rest := l.buf[l.pos:]
	i := bytes.IndexByte(rest, '\n')
	if i < 0 {
		l.pos = len(l.buf)
		return rest, true
	}
	l.pos += i + 1
	return rest[:i], true
}

func (l *lines) nextInt() (int, error) {
	b, ok := l.next()
	if !ok {
		return 0, io.ErrUnexpectedEOF
	}
	if len(b) == 0 {
		return 0, fmt.Errorf("expected a number, got an empty line")
	}
	v := 0
	for _, c := range b {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("expected a number, got %q", b)
		}
		v = v*10 + int(c-'0')
	}
	return v, nil
}

func run(in io.Reader, out io.Writer) error {
	data, err := io.ReadAll(in)
	if err != nil {
		return err
	}
	ls := &lines{buf: data}
	n, err := ls.nextInt()
	if err != nil {
		return fmt.Errorf("reading pattern count: %w", err)
	}
	res := make([]byte, 0, 1<<20)
	var m regexvm.Matcher
	for p := 0; p < n; p++ {
		pat, ok := ls.next()
		if !ok {
			return fmt.Errorf("pattern %d: %w", p+1, io.ErrUnexpectedEOF)
		}
		cnt, err := ls.nextInt()
		if err != nil {
			return fmt.Errorf("pattern %d: reading subject count: %w", p+1, err)
		}
		re, err := regexvm.Compile(string(pat))
		if err != nil {
			return fmt.Errorf("pattern %d: %w", p+1, err)
		}
		m.Reset(re)
		ng := re.NumGroups()
		for i := 0; i < cnt; i++ {
			subj, ok := ls.next()
			if !ok {
				return fmt.Errorf("pattern %d: %w", p+1, io.ErrUnexpectedEOF)
			}
			if !m.Match(subj) {
				res = append(res, "no\n"...)
				continue
			}
			res = append(res, "match "...)
			res = appendInt(res, m.Start())
			res = append(res, ' ')
			res = appendInt(res, m.End())
			for g := 1; g <= ng; g++ {
				res = append(res, '|')
				if s, e, ok := m.Group(g); ok {
					res = appendInt(res, s)
					res = append(res, ',')
					res = appendInt(res, e)
				} else {
					res = append(res, '-')
				}
			}
			res = append(res, '\n')
		}
	}
	_, err = out.Write(res)
	return err
}

// appendInt appends the decimal form of a non-negative integer.
func appendInt(dst []byte, v int) []byte {
	if v == 0 {
		return append(dst, '0')
	}
	var tmp [20]byte
	i := len(tmp)
	for v > 0 {
		i--
		tmp[i] = byte('0' + v%10)
		v /= 10
	}
	return append(dst, tmp[i:]...)
}
