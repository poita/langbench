package textbuffer

import "bytes"

// Position is a location in the document: a 0-based line and a 0-based
// column. Column len(line) is the end of the line.
type Position struct {
	Line, Col int
}

// Compare orders positions lexicographically (line, then column). It returns
// -1, 0 or +1.
func (p Position) Compare(q Position) int {
	switch {
	case p.Line < q.Line:
		return -1
	case p.Line > q.Line:
		return 1
	case p.Col < q.Col:
		return -1
	case p.Col > q.Col:
		return 1
	}
	return 0
}

// Less reports whether p is before q.
func (p Position) Less(q Position) bool { return p.Compare(q) < 0 }

// endOf returns the position reached after laying text out starting at start.
func endOf(start Position, text []byte) Position {
	last := bytes.LastIndexByte(text, '\n')
	if last < 0 {
		return Position{start.Line, start.Col + len(text)}
	}
	return Position{start.Line + bytes.Count(text, newline), len(text) - last - 1}
}

var newline = []byte{'\n'}

// shift is the composed mapping used by multi-cursor edits. It maps positions
// at or after a (expressed in the document before any replacement of the
// command) to the current document, in which the text up to a has been
// replaced by text ending at b.
type shift struct {
	a, b Position
}

// forward maps an original position p >= a to the current document.
func (s *shift) forward(p Position) Position {
	if p.Line == s.a.Line {
		return Position{s.b.Line, s.b.Col + p.Col - s.a.Col}
	}
	return Position{p.Line + s.b.Line - s.a.Line, p.Col}
}

// inverse maps a current position p >= b back to original coordinates.
func (s *shift) inverse(p Position) Position {
	if p.Line == s.b.Line {
		return Position{s.a.Line, s.a.Col + p.Col - s.b.Col}
	}
	return Position{p.Line + s.a.Line - s.b.Line, p.Col}
}
