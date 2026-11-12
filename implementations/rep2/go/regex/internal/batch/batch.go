// Package batch implements the line-oriented batch protocol of the command-line
// tool: it reads patterns, each followed by a count and that many subjects,
// and writes one result line per subject.
//
// Input:
//
//	N
//	pattern_1
//	M_1
//	subject_1_1
//	...
//
// Output, one line per subject: "no", or "match START END" followed by
// "|S,E" (or "|-" if unset) for each capture group.
package batch

import (
	"bufio"
	"fmt"
	"io"
	"strconv"

	"example.com/regex"
)

const bufSize = 1 << 20

// Run processes the whole of r, writing results to w.
func Run(r io.Reader, w io.Writer) error {
	in := &lineReader{r: bufio.NewReaderSize(r, bufSize)}
	out := bufio.NewWriterSize(w, bufSize)

	n, err := in.readInt("pattern count")
	if err != nil {
		return err
	}
	var loc []int
	var line []byte
	for p := 0; p < n; p++ {
		pat, err := in.readLine()
		if err != nil {
			return fmt.Errorf("pattern %d: %w", p+1, err)
		}
		re, err := regex.Compile(string(pat))
		if err != nil {
			return fmt.Errorf("pattern %d: %w", p+1, err)
		}
		m, err := in.readInt("subject count")
		if err != nil {
			return fmt.Errorf("pattern %d: %w", p+1, err)
		}
		for i := 0; i < m; i++ {
			subj, err := in.readLine()
			if err != nil {
				return fmt.Errorf("pattern %d subject %d: %w", p+1, i+1, err)
			}
			var ok bool
			loc, ok = re.FindIndexBytes(subj, loc)
			line = appendResult(line[:0], loc, ok)
			if _, err := out.Write(line); err != nil {
				return err
			}
		}
	}
	return out.Flush()
}

// appendResult formats one result line, including the trailing newline.
func appendResult(b []byte, loc []int, ok bool) []byte {
	if !ok {
		return append(b, "no\n"...)
	}
	b = append(b, "match "...)
	b = strconv.AppendInt(b, int64(loc[0]), 10)
	b = append(b, ' ')
	b = strconv.AppendInt(b, int64(loc[1]), 10)
	for g := 2; g < len(loc); g += 2 {
		b = append(b, '|')
		if loc[g] < 0 {
			b = append(b, '-')
			continue
		}
		b = strconv.AppendInt(b, int64(loc[g]), 10)
		b = append(b, ',')
		b = strconv.AppendInt(b, int64(loc[g+1]), 10)
	}
	return append(b, '\n')
}

// lineReader reads '\n'-terminated lines verbatim.
type lineReader struct {
	r   *bufio.Reader
	buf []byte
}

// readLine returns the next line without its terminator. The slice is only
// valid until the next call. A final line lacking '\n' is accepted.
func (l *lineReader) readLine() ([]byte, error) {
	line, err := l.r.ReadSlice('\n')
	if err == bufio.ErrBufferFull { // very long line: accumulate
		l.buf = append(l.buf[:0], line...)
		for err == bufio.ErrBufferFull {
			line, err = l.r.ReadSlice('\n')
			l.buf = append(l.buf, line...)
		}
		line = l.buf
	}
	if err == io.EOF && len(line) > 0 {
		return line, nil
	}
	if err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		return nil, err
	}
	return line[:len(line)-1], nil
}

func (l *lineReader) readInt(what string) (int, error) {
	line, err := l.readLine()
	if err != nil {
		return 0, fmt.Errorf("reading %s: %w", what, err)
	}
	n, err := strconv.Atoi(string(line))
	if err != nil || n < 0 {
		return 0, fmt.Errorf("invalid %s %q", what, line)
	}
	return n, nil
}
