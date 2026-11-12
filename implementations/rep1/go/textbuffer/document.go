package textbuffer

import (
	"slices"
	"strings"
)

// document stores the text as a slice of lines. Lines are byte slices so that
// edits inside a line are in-place splices.
type document struct {
	lines [][]byte
}

func newDocument(lines []string) *document {
	if len(lines) == 0 {
		return &document{lines: [][]byte{{}}}
	}
	total := 0
	for _, l := range lines {
		total += len(l)
	}
	// One backing array for all lines. Each line's capacity is limited to its
	// length so that growing a line reallocates instead of overwriting its
	// neighbour.
	data := make([]byte, 0, total)
	out := make([][]byte, len(lines))
	for i, l := range lines {
		start := len(data)
		data = append(data, l...)
		out[i] = data[start:len(data):len(data)]
	}
	return &document{lines: out}
}

func (d *document) lineLen(i int) int { return len(d.lines[i]) }

// clamp forces (line, col) into the document: first the line, then the column.
func (d *document) clamp(line, col int) Position {
	line = min(max(line, 0), len(d.lines)-1)
	col = min(max(col, 0), len(d.lines[line]))
	return Position{line, col}
}

func (d *document) end() Position {
	last := len(d.lines) - 1
	return Position{last, len(d.lines[last])}
}

// prev returns the position one character before p; p must not be (0, 0).
func (d *document) prev(p Position) Position {
	if p.Col > 0 {
		return Position{p.Line, p.Col - 1}
	}
	return Position{p.Line - 1, len(d.lines[p.Line-1])}
}

// next returns the position one character after p; p must not be the end of
// the document.
func (d *document) next(p Position) Position {
	if p.Col < len(d.lines[p.Line]) {
		return Position{p.Line, p.Col + 1}
	}
	return Position{p.Line + 1, 0}
}

// slice returns the text between s and e (s <= e).
func (d *document) slice(s, e Position) string {
	if s == e {
		return ""
	}
	if s.Line == e.Line {
		return string(d.lines[s.Line][s.Col:e.Col])
	}
	var sb strings.Builder
	n := len(d.lines[s.Line]) - s.Col + e.Col + (e.Line - s.Line)
	for l := s.Line + 1; l < e.Line; l++ {
		n += len(d.lines[l])
	}
	sb.Grow(n)
	sb.Write(d.lines[s.Line][s.Col:])
	for l := s.Line + 1; l < e.Line; l++ {
		sb.WriteByte('\n')
		sb.Write(d.lines[l])
	}
	sb.WriteByte('\n')
	sb.Write(d.lines[e.Line][:e.Col])
	return sb.String()
}

// replace replaces the text between s and e (s <= e) with text, which may
// contain newlines.
func (d *document) replace(s, e Position, text string) {
	nl := strings.Count(text, "\n")
	if nl == 0 {
		if s.Line == e.Line {
			d.lines[s.Line] = spliceBytes(d.lines[s.Line], s.Col, e.Col, text)
			return
		}
		// The range spans lines and the replacement is a single piece: the
		// result is one line.
		first := append(d.lines[s.Line][:s.Col], text...)
		first = append(first, d.lines[e.Line][e.Col:]...)
		d.lines[s.Line] = first
		d.lines = slices.Delete(d.lines, s.Line+1, e.Line+1)
		return
	}

	// The replacement has nl+1 segments. The last one is glued to the tail
	// of the old end line; copy it out first, since it may alias the head.
	lastNL := strings.LastIndexByte(text, '\n')
	tail := d.lines[e.Line][e.Col:]
	last := make([]byte, 0, len(text)-lastNL-1+len(tail))
	last = append(last, text[lastNL+1:]...)
	last = append(last, tail...)

	firstNL := strings.IndexByte(text, '\n')
	repl := make([][]byte, 0, nl+1)
	repl = append(repl, append(d.lines[s.Line][:s.Col], text[:firstNL]...))
	for rest := text[firstNL+1 : lastNL+1]; len(rest) > 0; {
		i := strings.IndexByte(rest, '\n')
		repl = append(repl, []byte(rest[:i]))
		rest = rest[i+1:]
	}
	repl = append(repl, last)
	d.lines = slices.Replace(d.lines, s.Line, e.Line+1, repl...)
}

// spliceBytes replaces b[i:j] with ins, reusing b's storage when it fits.
func spliceBytes(b []byte, i, j int, ins string) []byte {
	oldLen := len(b)
	newLen := oldLen - (j - i) + len(ins)
	if newLen <= cap(b) {
		b = b[:max(oldLen, newLen)]
		copy(b[i+len(ins):], b[j:oldLen])
		copy(b[i:], ins)
		return b[:newLen]
	}
	out := make([]byte, newLen, newLen+newLen/4+16)
	copy(out, b[:i])
	copy(out[i:], ins)
	copy(out[i+len(ins):], b[j:])
	return out
}
