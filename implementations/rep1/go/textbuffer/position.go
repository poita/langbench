package textbuffer

import "strings"

// Position identifies a point in the document. Both fields are zero-based;
// Col is a byte index into the line and may equal the line's length (the end
// of the line).
type Position struct {
	Line int
	Col  int
}

// Compare returns -1, 0 or +1 according to whether p sorts before, equal to
// or after q (by line, then by column).
func (p Position) Compare(q Position) int {
	switch {
	case p.Line != q.Line:
		if p.Line < q.Line {
			return -1
		}
		return 1
	case p.Col != q.Col:
		if p.Col < q.Col {
			return -1
		}
		return 1
	}
	return 0
}

// Less reports whether p sorts strictly before q.
func (p Position) Less(q Position) bool { return p.Compare(q) < 0 }

// minPos and maxPos return the smaller and larger of two positions.
func minPos(a, b Position) Position {
	if b.Less(a) {
		return b
	}
	return a
}

func maxPos(a, b Position) Position {
	if a.Less(b) {
		return b
	}
	return a
}

// advance returns the position reached after inserting text at p.
func advance(p Position, text string) Position {
	nl := strings.Count(text, "\n")
	if nl == 0 {
		return Position{p.Line, p.Col + len(text)}
	}
	return Position{p.Line + nl, len(text) - strings.LastIndexByte(text, '\n') - 1}
}
