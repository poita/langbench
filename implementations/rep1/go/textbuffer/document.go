package textbuffer

import "bytes"

// document is the text of a buffer: a lineStore plus the splice routine that
// every edit, undo and redo goes through.
type document struct {
	lines   lineStore
	scratch [][]byte
}

func newDocument(lines [][]byte) *document {
	if len(lines) == 0 {
		lines = [][]byte{nil}
	}
	return &document{lines: newLineStore(lines)}
}

func (d *document) lineCount() int { return d.lines.count() }

func (d *document) line(i int) []byte { return d.lines.at(i) }

// extract returns a fresh copy of the text between s and e (s <= e).
func (d *document) extract(s, e Position) []byte {
	if s.Line == e.Line {
		return bytes.Clone(d.line(s.Line)[s.Col:e.Col])
	}
	n := len(d.line(s.Line)) - s.Col + 1 + e.Col
	for i := s.Line + 1; i < e.Line; i++ {
		n += len(d.line(i)) + 1
	}
	out := make([]byte, 0, n)
	out = append(out, d.line(s.Line)[s.Col:]...)
	for i := s.Line + 1; i < e.Line; i++ {
		out = append(out, '\n')
		out = append(out, d.line(i)...)
	}
	out = append(out, '\n')
	return append(out, d.line(e.Line)[:e.Col]...)
}

// splice replaces the text between s and e (s <= e) by text, which may
// contain newlines, and returns the position just after the inserted text.
// text is copied, never retained.
func (d *document) splice(s, e Position, text []byte) Position {
	nl := bytes.IndexByte(text, '\n')
	if nl < 0 {
		if s.Line == e.Line {
			d.lines.set(s.Line, spliceBytes(d.line(s.Line), s.Col, e.Col, text))
		} else {
			buf := append(d.line(s.Line)[:s.Col], text...)
			buf = append(buf, d.line(e.Line)[e.Col:]...)
			d.scratch = append(d.scratch[:0], buf)
			d.lines.replace(s.Line, e.Line-s.Line+1, d.scratch)
		}
		return Position{s.Line, s.Col + len(text)}
	}

	// Several pieces. Build the last line first: it may share storage with
	// the first when the range lies within one line.
	lastNL := bytes.LastIndexByte(text, '\n')
	lastPiece := text[lastNL+1:]
	suffix := d.line(e.Line)[e.Col:]
	lastBuf := make([]byte, 0, len(lastPiece)+len(suffix))
	lastBuf = append(lastBuf, lastPiece...)
	lastBuf = append(lastBuf, suffix...)

	repl := append(d.scratch[:0], append(d.line(s.Line)[:s.Col], text[:nl]...))
	rest := text[nl+1 : lastNL+1]
	for len(rest) > 0 {
		i := bytes.IndexByte(rest, '\n')
		repl = append(repl, bytes.Clone(rest[:i]))
		rest = rest[i+1:]
	}
	repl = append(repl, lastBuf)
	d.scratch = repl
	d.lines.replace(s.Line, e.Line-s.Line+1, repl)
	clear(d.scratch)
	return Position{s.Line + len(repl) - 1, len(lastPiece)}
}

// spliceBytes replaces line[a:b] by text, reusing line's capacity when it can.
func spliceBytes(line []byte, a, b int, text []byte) []byte {
	n := len(line) - (b - a) + len(text)
	if n > cap(line) {
		out := make([]byte, n, n+n/2+8)
		copy(out, line[:a])
		copy(out[a:], text)
		copy(out[a+len(text):], line[b:])
		return out
	}
	tail := line[b:]
	old := len(line)
	line = line[:max(n, old)]
	copy(line[a+len(text):], tail)
	copy(line[a:], text)
	return line[:n]
}
