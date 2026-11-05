// Package batch implements the command-line tool's input/output contract:
// a list of patterns, each followed by subjects, answered with one result
// line per subject.
package batch

import (
	"errors"
	"fmt"
	"io"

	"example.com/regex"
)

const flushThreshold = 8 << 20

type reader struct {
	data []byte
	pos  int
}

// line returns the next line without its terminator. The final line may lack
// a terminator.
func (r *reader) line() ([]byte, bool) {
	if r.pos >= len(r.data) {
		return nil, false
	}
	rest := r.data[r.pos:]
	for i, c := range rest {
		if c == '\n' {
			r.pos += i + 1
			return rest[:i], true
		}
	}
	r.pos = len(r.data)
	return rest, true
}

func (r *reader) count() (int, error) {
	l, ok := r.line()
	if !ok {
		return 0, errors.New("unexpected end of input")
	}
	if len(l) == 0 {
		return 0, errors.New("empty count line")
	}
	v := 0
	for _, c := range l {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("invalid count %q", l)
		}
		v = v*10 + int(c-'0')
	}
	return v, nil
}

// Run processes the whole input and writes the results to w.
func Run(input []byte, w io.Writer) error {
	r := &reader{data: input}
	np, err := r.count()
	if err != nil {
		return err
	}
	out := make([]byte, 0, 1<<20)
	var m regex.Matcher
	for p := 0; p < np; p++ {
		pat, ok := r.line()
		if !ok {
			return fmt.Errorf("pattern %d: unexpected end of input", p+1)
		}
		ns, err := r.count()
		if err != nil {
			return fmt.Errorf("pattern %d: %w", p+1, err)
		}
		re, err := regex.Compile(string(pat))
		if err != nil {
			return fmt.Errorf("pattern %d: %w", p+1, err)
		}
		m.Reset(re)
		ng := re.NumGroups()
		for i := 0; i < ns; i++ {
			subj, ok := r.line()
			if !ok {
				if i == ns-1 && p == np-1 {
					subj = nil // tolerate a missing final empty line
				} else {
					return fmt.Errorf("pattern %d: unexpected end of input", p+1)
				}
			}
			if !m.Find(subj) {
				out = append(out, "no\n"...)
				continue
			}
			s, e := m.Span()
			out = append(out, "match "...)
			out = appendInt(out, s)
			out = append(out, ' ')
			out = appendInt(out, e)
			for g := 1; g <= ng; g++ {
				out = append(out, '|')
				if gs, ge, ok := m.Group(g); ok {
					out = appendInt(out, gs)
					out = append(out, ',')
					out = appendInt(out, ge)
				} else {
					out = append(out, '-')
				}
			}
			out = append(out, '\n')
			if len(out) >= flushThreshold {
				if _, err := w.Write(out); err != nil {
					return err
				}
				out = out[:0]
			}
		}
	}
	_, err = w.Write(out)
	return err
}

// appendInt appends the decimal form of a non-negative v.
func appendInt(b []byte, v int) []byte {
	if v == 0 {
		return append(b, '0')
	}
	var tmp [20]byte
	i := len(tmp)
	for v > 0 {
		i--
		tmp[i] = byte('0' + v%10)
		v /= 10
	}
	return append(b, tmp[i:]...)
}
