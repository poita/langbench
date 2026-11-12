package textbuffer

type editKind int

const (
	editInsert editKind = iota
	editBackspace
	editDeleteForward
)

// Insert inserts text at every cursor, replacing selections. text may contain
// '\n' characters, which start new lines. Each cursor ends after its inserted
// text with no selection. The command is one undo step.
func (b *Buffer) Insert(text string) { b.edit(editInsert, text) }

// Delete deletes each selection, or, for a cursor without one, the character
// before it (the newline joining the line to the previous one when the cursor
// is at column 0). A cursor at the start of the document does nothing. The
// command is one undo step if it changed the document.
func (b *Buffer) Delete() { b.edit(editBackspace, "") }

// DeleteForward deletes each selection, or, for a cursor without one, the
// character after it (the newline joining the line to the next one when the
// cursor is at the end of its line). A cursor at the end of the document does
// nothing. The command is one undo step if it changed the document.
func (b *Buffer) DeleteForward() { b.edit(editDeleteForward, "") }

// shift maps positions of the document as it was before an edit command into
// the document as it is after the replacements made so far, in O(1).
//
// It relies on every position being mapped lying at or after the end of all
// replacements made so far. Lines after the last replacement's end line only
// move by lineDelta; positions on that line also move by colDelta.
type shift struct {
	lineDelta int
	lastLine  int // original line where the last replacement ended
	colDelta  int // column shift for original positions on lastLine
}

func (s *shift) apply(p Position) Position {
	if p.Line == s.lastLine {
		return Position{p.Line + s.lineDelta, p.Col + s.colDelta}
	}
	return Position{p.Line + s.lineDelta, p.Col}
}

// record updates the shift after a replacement whose range ended at end (a position
// in the current document) and whose inserted text ends at newEnd.
func (s *shift) record(end, newEnd Position) {
	origLine := end.Line - s.lineDelta
	origCol := end.Col
	if origLine == s.lastLine {
		origCol -= s.colDelta
	}
	s.lastLine = origLine
	s.colDelta = newEnd.Col - origCol
	s.lineDelta += newEnd.Line - end.Line
}

func (b *Buffer) edit(kind editKind, text string) {
	d := b.doc
	before := make([]Cursor, len(b.cursors))
	copy(before, b.cursors)
	reps := make([]replacement, 0, len(b.cursors))
	sh := shift{lastLine: -1}

	for i := range b.cursors {
		c := &b.cursors[i]
		head := sh.apply(c.Head)
		start, end := head, head
		if c.Selected {
			anchor := sh.apply(c.Anchor)
			start, end = minPos(head, anchor), maxPos(head, anchor)
		}
		ins := ""
		switch {
		case kind == editInsert:
			ins = text
		case c.Selected:
		case kind == editBackspace:
			if head != (Position{}) {
				start = d.prev(head)
			}
		default:
			if head != d.end() {
				end = d.next(head)
			}
		}

		c.Selected = false
		if start == end && ins == "" {
			c.Head = head // nothing to replace
			continue
		}
		removed := d.slice(start, end)
		d.replace(start, end, ins)
		reps = append(reps, replacement{start, removed, ins})
		newEnd := advance(start, ins)
		sh.record(end, newEnd)
		c.Head = newEnd
	}

	b.cursors = normalize(b.cursors)
	b.resetGoals()
	if len(reps) == 0 {
		return
	}
	after := make([]Cursor, len(b.cursors))
	copy(after, b.cursors)
	b.undo = append(b.undo, entry{before: before, after: after, reps: reps})
	clear(b.redo)
	b.redo = b.redo[:0]
}
