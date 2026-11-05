package textbuffer

import (
	"bytes"
	"slices"
	"strings"
)

// Buffer is a multi-line text document with a set of cursors and an
// undo/redo history. The zero value is not usable; create one with [New] or
// [NewFromLines]. A Buffer is not safe for concurrent use.
type Buffer struct {
	doc     *document
	cursors []Cursor
	undo    []entry
	redo    []entry
	scratch []Cursor // reused snapshot of the cursors before an edit
	reps    []replacement
}

// New returns a buffer holding the given lines. Lines must not contain
// newlines. With no lines the buffer holds one empty line. There is one
// primary cursor at (0, 0).
func New(lines ...string) *Buffer {
	bl := make([][]byte, len(lines))
	for i, l := range lines {
		bl[i] = []byte(l)
	}
	return newBuffer(bl)
}

// NewFromLines is like [New] for byte-slice lines. The lines are copied.
func NewFromLines(lines [][]byte) *Buffer {
	bl := make([][]byte, len(lines))
	for i, l := range lines {
		bl[i] = bytes.Clone(l)
	}
	return newBuffer(bl)
}

// NewFromText returns a buffer holding text split at newlines.
func NewFromText(text string) *Buffer {
	return New(strings.Split(text, "\n")...)
}

func newBuffer(lines [][]byte) *Buffer {
	return &Buffer{
		doc:     newDocument(lines),
		cursors: []Cursor{{Primary: true}},
	}
}

// LineCount returns the number of lines, always at least 1.
func (b *Buffer) LineCount() int { return b.doc.lineCount() }

// Line returns line i without its newline. The result aliases the buffer's
// storage: it must not be modified and is valid only until the next call
// that changes the document (including Undo and Redo).
func (b *Buffer) Line(i int) []byte { return b.doc.line(i) }

// Text returns the whole document with lines joined by newlines.
func (b *Buffer) Text() string {
	var sb strings.Builder
	for i, n := 0, b.LineCount(); i < n; i++ {
		if i > 0 {
			sb.WriteByte('\n')
		}
		sb.Write(b.doc.line(i))
	}
	return sb.String()
}

// Cursors returns a copy of the cursors in cursor order.
func (b *Buffer) Cursors() []Cursor { return slices.Clone(b.cursors) }

// NumCursors returns the number of cursors.
func (b *Buffer) NumCursors() int { return len(b.cursors) }

// Cursor returns the i-th cursor in cursor order.
func (b *Buffer) Cursor(i int) Cursor { return b.cursors[i] }

// Clamp returns the nearest valid position to (line, col): the line is
// clamped to [0, LineCount-1], then the column to [0, len(line)].
func (b *Buffer) Clamp(line, col int) Position {
	line = min(max(line, 0), b.LineCount()-1)
	col = min(max(col, 0), len(b.doc.line(line)))
	return Position{line, col}
}

// Goto replaces all cursors by one primary cursor at the clamped position.
func (b *Buffer) Goto(line, col int) {
	b.cursors = append(b.cursors[:0], Cursor{Head: b.Clamp(line, col), Primary: true})
	b.finishCursorCommand()
}

// AddCursor adds a non-primary cursor at the clamped position. If the
// position lies on or inside an existing cursor the cursors merge.
func (b *Buffer) AddCursor(line, col int) {
	b.cursors = append(b.cursors, Cursor{Head: b.Clamp(line, col)})
	b.finishCursorCommand()
}

// ClearCursors removes every cursor except the primary one, which keeps its
// selection.
func (b *Buffer) ClearCursors() {
	for _, c := range b.cursors {
		if c.Primary {
			b.cursors = append(b.cursors[:0], c)
			break
		}
	}
	b.finishCursorCommand()
}

// finishCursorCommand normalizes the cursors and resets the goal columns.
func (b *Buffer) finishCursorCommand() {
	b.cursors = normalize(b.cursors)
	b.resetGoals()
}

func (b *Buffer) resetGoals() {
	for i := range b.cursors {
		b.cursors[i].Goal = b.cursors[i].Head.Col
	}
}
