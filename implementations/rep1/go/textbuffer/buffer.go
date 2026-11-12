package textbuffer

import (
	"io"
	"slices"
	"strings"
)

// Buffer is a text document with a set of cursors and an undo/redo history.
// The zero value is not usable; create one with [New] or [NewFromLines]. A
// Buffer is not safe for concurrent use.
type Buffer struct {
	doc     *document
	cursors []Cursor // always normalized: cursor order, distinct starts
	undo    []entry
	redo    []entry
}

// New creates a buffer holding text, split into lines at '\n'. The empty
// string gives a document of one empty line. There is a single primary cursor
// at (0, 0).
func New(text string) *Buffer {
	return NewFromLines(strings.Split(text, "\n"))
}

// NewFromLines creates a buffer whose document is the given lines (none of
// which may contain '\n'). No lines means one empty line. There is a single
// primary cursor at (0, 0).
func NewFromLines(lines []string) *Buffer {
	return &Buffer{
		doc:     newDocument(lines),
		cursors: []Cursor{{Primary: true}},
	}
}

// LineCount returns the number of lines in the document (at least 1).
func (b *Buffer) LineCount() int { return len(b.doc.lines) }

// Line returns the text of line i, without its newline. It panics if i is out
// of range.
func (b *Buffer) Line(i int) string { return string(b.doc.lines[i]) }

// LineLen returns the length in bytes of line i. It panics if i is out of
// range.
func (b *Buffer) LineLen(i int) int { return b.doc.lineLen(i) }

// Lines returns a copy of the document's lines.
func (b *Buffer) Lines() []string {
	out := make([]string, len(b.doc.lines))
	for i, l := range b.doc.lines {
		out[i] = string(l)
	}
	return out
}

// Text returns the document text: the lines joined by '\n', with no trailing
// newline.
func (b *Buffer) Text() string {
	var sb strings.Builder
	b.WriteTo(&sb)
	return sb.String()
}

// WriteTo writes the document text (as returned by Text) to w. It implements
// [io.WriterTo].
func (b *Buffer) WriteTo(w io.Writer) (int64, error) {
	var total int64
	for i, l := range b.doc.lines {
		if i > 0 {
			n, err := w.Write([]byte{'\n'})
			total += int64(n)
			if err != nil {
				return total, err
			}
		}
		n, err := w.Write(l)
		total += int64(n)
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// SelectedText returns the text covered by cursor i's range.
func (b *Buffer) SelectedText(i int) string {
	c := b.cursors[i]
	return b.doc.slice(c.Start(), c.End())
}

// CursorCount returns the number of cursors (at least 1).
func (b *Buffer) CursorCount() int { return len(b.cursors) }

// Cursors returns a copy of the cursors in cursor order (ascending range
// start).
func (b *Buffer) Cursors() []Cursor { return slices.Clone(b.cursors) }

// Primary returns the primary cursor.
func (b *Buffer) Primary() Cursor {
	for _, c := range b.cursors {
		if c.Primary {
			return c
		}
	}
	panic("textbuffer: no primary cursor")
}

// Clamp forces (line, col) into the document: line is clamped to the existing
// lines first, then col to the length of that line.
func (b *Buffer) Clamp(line, col int) Position { return b.doc.clamp(line, col) }

// GoTo replaces all cursors by a single primary cursor at (line, col), which
// is clamped into the document. It does not touch the history.
func (b *Buffer) GoTo(line, col int) {
	p := b.doc.clamp(line, col)
	b.cursors = append(b.cursors[:0], Cursor{Head: p, Primary: true, Goal: p.Col})
}

// AddCursor adds a non-primary cursor at (line, col), which is clamped into
// the document. If the position lies on or inside an existing cursor, the
// cursors merge and the count does not grow. It does not touch the history.
func (b *Buffer) AddCursor(line, col int) {
	p := b.doc.clamp(line, col)
	b.cursors = append(b.cursors, Cursor{Head: p})
	b.finishCommand()
}

// ClearCursors removes every cursor except the primary one, which keeps its
// selection. It does not touch the history.
func (b *Buffer) ClearCursors() {
	for _, c := range b.cursors {
		if c.Primary {
			b.cursors = append(b.cursors[:0], c)
			break
		}
	}
	b.finishCommand()
}

// CanUndo reports whether Undo would do anything.
func (b *Buffer) CanUndo() bool { return len(b.undo) > 0 }

// CanRedo reports whether Redo would do anything.
func (b *Buffer) CanRedo() bool { return len(b.redo) > 0 }

// Undo reverts the most recent edit command (however many cursors took part)
// and restores the cursors as they were before it. It reports whether there
// was anything to undo.
func (b *Buffer) Undo() bool {
	n := len(b.undo)
	if n == 0 {
		b.resetGoals() // goal columns are reset even when nothing happens
		return false
	}
	e := b.undo[n-1]
	b.undo[n-1] = entry{}
	b.undo = b.undo[:n-1]
	e.applyBackward(b.doc)
	b.cursors = slices.Clone(e.before)
	b.resetGoals()
	b.redo = append(b.redo, e)
	return true
}

// Redo re-applies the most recently undone edit command and restores the
// cursors as they were after it. It reports whether there was anything to
// redo.
func (b *Buffer) Redo() bool {
	n := len(b.redo)
	if n == 0 {
		b.resetGoals() // goal columns are reset even when nothing happens
		return false
	}
	e := b.redo[n-1]
	b.redo[n-1] = entry{}
	b.redo = b.redo[:n-1]
	e.applyForward(b.doc)
	b.cursors = slices.Clone(e.after)
	b.resetGoals()
	b.undo = append(b.undo, e)
	return true
}

// finishCommand normalizes the cursor set and resets every goal column to its
// head's column. Every command except vertical moves ends this way.
func (b *Buffer) finishCommand() {
	b.cursors = normalize(b.cursors)
	b.resetGoals()
}

func (b *Buffer) resetGoals() {
	for i := range b.cursors {
		b.cursors[i].Goal = b.cursors[i].Head.Col
	}
}
