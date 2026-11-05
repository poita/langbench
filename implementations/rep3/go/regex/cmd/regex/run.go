package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"

	"regex"
)

// flushThreshold is the output buffer size at which run writes it out.
const flushThreshold = 1 << 22

// lines walks input as (start, end) views, one per '\n'-terminated line.
type lines struct {
	data []byte
	pos  int
}

var errEOF = errors.New("unexpected end of input")

// next returns the next line without its terminator. A final line lacking
// '\n' is tolerated.
func (l *lines) next() ([]byte, error) {
	if l.pos >= len(l.data) {
		return nil, errEOF
	}
	rest := l.data[l.pos:]
	i := bytes.IndexByte(rest, '\n')
	if i < 0 {
		l.pos = len(l.data)
		return rest, nil
	}
	l.pos += i + 1
	return rest[:i], nil
}

// nextInt reads a line holding a plain decimal count.
func (l *lines) nextInt() (int, error) {
	line, err := l.next()
	if err != nil {
		return 0, err
	}
	if len(line) == 0 {
		return 0, errors.New("expected a number, found an empty line")
	}
	n := 0
	for _, c := range line {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("expected a number, found %q", line)
		}
		n = n*10 + int(c-'0')
	}
	return n, nil
}

// run processes the whole input and writes the results to w.
func run(data []byte, w io.Writer) error {
	ls := &lines{data: data}
	np, err := ls.nextInt()
	if err != nil {
		return fmt.Errorf("pattern count: %w", err)
	}
	out := make([]byte, 0, 1<<16)
	flush := func(force bool) error {
		if len(out) >= flushThreshold || force && len(out) > 0 {
			_, err := w.Write(out)
			out = out[:0]
			return err
		}
		return nil
	}
	for pi := 1; pi <= np; pi++ {
		pat, err := ls.next()
		if err != nil {
			return fmt.Errorf("pattern %d: %w", pi, err)
		}
		m, err := ls.nextInt()
		if err != nil {
			return fmt.Errorf("pattern %d subject count: %w", pi, err)
		}
		re, cerr := regex.Compile(string(pat))
		if cerr != nil {
			if ferr := flush(true); ferr != nil {
				return ferr
			}
			return fmt.Errorf("pattern %d: %w", pi, cerr)
		}
		matcher := re.NewMatcher()
		ng := re.NumGroups()
		for si := 0; si < m; si++ {
			subj, err := ls.next()
			if err != nil {
				return fmt.Errorf("pattern %d subject %d: %w", pi, si+1, err)
			}
			if !matcher.Find(subj) {
				out = append(out, "no\n"...)
			} else {
				out = appendMatch(out, matcher, ng)
			}
			if len(out) >= flushThreshold {
				if err := flush(false); err != nil {
					return err
				}
			}
		}
	}
	return flush(true)
}

// appendMatch appends "match S E|gs,ge|-...\n" for the matcher's last match.
func appendMatch(out []byte, m *regex.Matcher, groups int) []byte {
	out = append(out, "match "...)
	out = appendUint(out, m.Start())
	out = append(out, ' ')
	out = appendUint(out, m.End())
	for g := 1; g <= groups; g++ {
		out = append(out, '|')
		s, e, ok := m.Group(g)
		if !ok {
			out = append(out, '-')
			continue
		}
		out = appendUint(out, s)
		out = append(out, ',')
		out = appendUint(out, e)
	}
	return append(out, '\n')
}

// appendUint appends the decimal digits of a non-negative n.
func appendUint(out []byte, n int) []byte {
	if n == 0 {
		return append(out, '0')
	}
	var tmp [20]byte
	i := len(tmp)
	for n > 0 {
		i--
		tmp[i] = byte('0' + n%10)
		n /= 10
	}
	return append(out, tmp[i:]...)
}
