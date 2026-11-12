// Package cli implements the line-oriented command protocol of the
// ordered-map command-line tool on top of the orderedmap library.
package cli

import (
	"bufio"
	"io"
	"strconv"
	"strings"

	orderedmap "example.com/orderedmap"
)

// Run reads a command count followed by that many commands from r, executes
// them against a fresh map and writes one output line per command to w.
// Input is assumed well formed (see SPEC.md); a command that cannot be
// parsed produces an error.
func Run(r io.Reader, w io.Writer) error {
	br := bufio.NewReaderSize(r, 1<<16)
	bw := bufio.NewWriterSize(w, 1<<16)

	first, err := readLine(br)
	if err != nil && first == "" {
		if err == io.EOF {
			return nil
		}
		return err
	}
	q, err := strconv.Atoi(strings.TrimSpace(first))
	if err != nil {
		return err
	}

	m := orderedmap.New()
	var buf []byte
	for i := 0; i < q; i++ {
		line, rerr := readLine(br)
		if rerr != nil && line == "" {
			if rerr == io.EOF {
				break
			}
			return rerr
		}
		buf, err = Exec(m, line, buf[:0])
		if err != nil {
			bw.Flush()
			return err
		}
		buf = append(buf, '\n')
		if _, err = bw.Write(buf); err != nil {
			return err
		}
	}
	return bw.Flush()
}

// readLine returns the next line without its terminator.
func readLine(br *bufio.Reader) (string, error) {
	line, err := br.ReadString('\n')
	line = strings.TrimSuffix(line, "\n")
	line = strings.TrimSuffix(line, "\r")
	return line, err
}

// Exec executes a single command line against m and appends its output
// (without a trailing newline) to dst.
func Exec(m *orderedmap.Map, line string, dst []byte) ([]byte, error) {
	cmd, rest, _ := strings.Cut(line, " ")
	switch cmd {
	case "insert":
		ks, val, _ := strings.Cut(rest, " ")
		k, err := strconv.ParseInt(ks, 10, 64)
		if err != nil {
			return dst, err
		}
		if m.Put(k, val) {
			return append(dst, "updated"...), nil
		}
		return append(dst, "ok"...), nil
	case "delete":
		k, err := strconv.ParseInt(rest, 10, 64)
		if err != nil {
			return dst, err
		}
		if m.Delete(k) {
			return append(dst, "ok"...), nil
		}
		return append(dst, "missing"...), nil
	case "get":
		k, err := strconv.ParseInt(rest, 10, 64)
		if err != nil {
			return dst, err
		}
		if v, ok := m.Get(k); ok {
			return append(dst, v...), nil
		}
		return append(dst, "missing"...), nil
	case "size":
		return strconv.AppendInt(dst, int64(m.Len()), 10), nil
	case "min":
		return appendKey(dst, "empty")(m.Min())
	case "max":
		return appendKey(dst, "empty")(m.Max())
	case "floor", "ceil", "succ", "pred":
		k, err := strconv.ParseInt(rest, 10, 64)
		if err != nil {
			return dst, err
		}
		var (
			res int64
			ok  bool
		)
		switch cmd {
		case "floor":
			res, ok = m.Floor(k)
		case "ceil":
			res, ok = m.Ceil(k)
		case "succ":
			res, ok = m.Successor(k)
		default:
			res, ok = m.Predecessor(k)
		}
		return appendKey(dst, "missing")(res, ok)
	case "rank":
		k, err := strconv.ParseInt(rest, 10, 64)
		if err != nil {
			return dst, err
		}
		return strconv.AppendInt(dst, int64(m.Rank(k)), 10), nil
	case "select":
		k, err := strconv.ParseInt(rest, 10, 64)
		if err != nil {
			return dst, err
		}
		if k > int64(m.Len()) { // also guards int conversion
			return append(dst, "missing"...), nil
		}
		return appendKey(dst, "missing")(m.Select(int(k)))
	case "range":
		los, his, _ := strings.Cut(rest, " ")
		lo, err := strconv.ParseInt(los, 10, 64)
		if err != nil {
			return dst, err
		}
		hi, err := strconv.ParseInt(his, 10, 64)
		if err != nil {
			return dst, err
		}
		start := len(dst)
		m.Range(lo, hi, func(key int64, _ string) bool {
			if len(dst) > start {
				dst = append(dst, ' ')
			}
			dst = strconv.AppendInt(dst, key, 10)
			return true
		})
		if len(dst) == start {
			dst = append(dst, "empty"...)
		}
		return dst, nil
	}
	return dst, &UnknownCommandError{Line: line}
}

// UnknownCommandError is returned for a line whose command word is not
// recognised.
type UnknownCommandError struct{ Line string }

func (e *UnknownCommandError) Error() string { return "unknown command: " + e.Line }

// appendKey returns a function that formats an (int64, ok) result, using
// none as the text for the not-found case.
func appendKey(dst []byte, none string) func(int64, bool) ([]byte, error) {
	return func(k int64, ok bool) ([]byte, error) {
		if !ok {
			return append(dst, none...), nil
		}
		return strconv.AppendInt(dst, k, 10), nil
	}
}
