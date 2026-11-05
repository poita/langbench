// Package script interprets the line-oriented command language of the
// textbuffer command-line tool: an initial document followed by editing
// commands, with one dump of the document and cursors per print command.
package script

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"strconv"

	"textbuffer"
)

// Run executes the script in input and writes the output of every print
// command to w. On a malformed script it stops, flushes what was produced so
// far and returns an error naming the offending line.
func Run(input []byte, w io.Writer) error {
	out := bufio.NewWriterSize(w, 1<<20)
	err := run(input, out)
	if ferr := out.Flush(); err == nil {
		err = ferr
	}
	return err
}

// lineReader walks a byte buffer line by line without copying.
type lineReader struct {
	data []byte
	pos  int
	num  int
}

func (r *lineReader) next() ([]byte, bool) {
	if r.pos >= len(r.data) {
		return nil, false
	}
	rest := r.data[r.pos:]
	i := bytes.IndexByte(rest, '\n')
	if i < 0 {
		i = len(rest)
		r.pos = len(r.data)
	} else {
		r.pos += i + 1
	}
	r.num++
	return rest[:i], true
}

func run(input []byte, out *bufio.Writer) error {
	r := &lineReader{data: input}
	header, ok := r.next()
	n := 0
	if ok {
		v, err := parseUint(bytes.TrimSpace(header))
		if err != nil {
			return fmt.Errorf("line 1: bad line count: %w", err)
		}
		n = v
	}
	lines := make([][]byte, 0, n)
	for i := 0; i < n; i++ {
		l, ok := r.next()
		if !ok {
			break
		}
		lines = append(lines, l)
	}
	buf := textbuffer.NewFromLines(lines)

	var decoded, num []byte
	for {
		line, ok := r.next()
		if !ok {
			return nil
		}
		word, arg := line, []byte(nil)
		hasArg := false
		if i := bytes.IndexByte(line, ' '); i >= 0 {
			word, arg, hasArg = line[:i], line[i+1:], true
		}
		bad := func(msg string) error {
			return fmt.Errorf("line %d: %s: %q", r.num, msg, line)
		}
		switch string(word) {
		case "insert":
			if !hasArg || len(arg) == 0 {
				return bad("insert needs text")
			}
			text := arg
			if bytes.IndexByte(arg, '\\') >= 0 {
				decoded = decodeEscapes(decoded[:0], arg)
				text = decoded
			}
			buf.Insert(text)
		case "delete":
			buf.Delete()
		case "delete-forward":
			buf.DeleteForward()
		case "move":
			dirWord, selWord, _ := bytes.Cut(arg, []byte(" "))
			dir, ok := textbuffer.ParseDirection(string(dirWord))
			if !hasArg || !ok {
				return bad("bad move direction")
			}
			extend := false
			switch string(selWord) {
			case "":
			case "select":
				extend = true
			default:
				return bad("bad move modifier")
			}
			buf.Move(dir, extend)
		case "goto", "add-cursor":
			a, b, ok := bytes.Cut(arg, []byte(" "))
			if !hasArg || !ok {
				return bad("expected <line> <col>")
			}
			l, err1 := parseUint(a)
			c, err2 := parseUint(b)
			if err1 != nil || err2 != nil {
				return bad("bad number")
			}
			if word[0] == 'g' {
				buf.Goto(l, c)
			} else {
				buf.AddCursor(l, c)
			}
		case "clear-cursors":
			buf.ClearCursors()
		case "undo":
			buf.Undo()
		case "redo":
			buf.Redo()
		case "print":
			num = printBuffer(out, buf, num)
		default:
			return bad("unknown command")
		}
	}
}

// printBuffer writes the document lines, the cursor heads and a "--" line.
func printBuffer(out *bufio.Writer, buf *textbuffer.Buffer, num []byte) []byte {
	for i, n := 0, buf.LineCount(); i < n; i++ {
		out.Write(buf.Line(i))
		out.WriteByte('\n')
	}
	for i, n := 0, buf.NumCursors(); i < n; i++ {
		h := buf.Cursor(i).Head
		out.WriteString("cursor ")
		num = strconv.AppendInt(num[:0], int64(h.Line), 10)
		num = append(num, ' ')
		num = strconv.AppendInt(num, int64(h.Col), 10)
		num = append(num, '\n')
		out.Write(num)
	}
	out.WriteString("--\n")
	return num
}

// decodeEscapes appends src to dst, turning \n into a newline and \\ into a
// backslash. A backslash followed by anything else is kept as is.
func decodeEscapes(dst, src []byte) []byte {
	for i := 0; i < len(src); i++ {
		c := src[i]
		if c == '\\' && i+1 < len(src) {
			switch src[i+1] {
			case 'n':
				c = '\n'
				i++
			case '\\':
				i++
			}
		}
		dst = append(dst, c)
	}
	return dst
}

// parseUint parses a non-negative decimal integer, saturating at 1<<30 (far
// beyond any document, so the value clamps the same way).
func parseUint(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, fmt.Errorf("empty number")
	}
	v := 0
	for _, c := range b {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("invalid number %q", b)
		}
		if v < 1<<30 {
			v = v*10 + int(c-'0')
		}
	}
	return v, nil
}
