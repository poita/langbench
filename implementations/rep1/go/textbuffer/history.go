package textbuffer

// replacement is one splice of an edit command: the text removed and the text
// inserted at start, where start is expressed in the document as it was
// immediately before this replacement was applied.
type replacement struct {
	start    Position
	removed  []byte
	inserted []byte // shared by all replacements of an insert command
}

// entry is one undo step: one edit command.
type entry struct {
	before, after []Cursor
	reps          []replacement
}

func (b *Buffer) pushUndo(e entry) {
	b.undo = append(b.undo, e)
	clear(b.redo)
	b.redo = b.redo[:0]
}

// Undo reverts the most recent edit command and restores the cursors as they
// were before it. It reports whether there was anything to undo.
func (b *Buffer) Undo() bool {
	n := len(b.undo)
	if n == 0 {
		b.resetGoals()
		return false
	}
	e := b.undo[n-1]
	b.undo[n-1] = entry{}
	b.undo = b.undo[:n-1]
	for i := len(e.reps) - 1; i >= 0; i-- {
		r := e.reps[i]
		b.doc.splice(r.start, endOf(r.start, r.inserted), r.removed)
	}
	b.cursors = append(b.cursors[:0], e.before...)
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
		b.resetGoals()
		return false
	}
	e := b.redo[n-1]
	b.redo[n-1] = entry{}
	b.redo = b.redo[:n-1]
	for _, r := range e.reps {
		b.doc.splice(r.start, endOf(r.start, r.removed), r.inserted)
	}
	b.cursors = append(b.cursors[:0], e.after...)
	b.resetGoals()
	b.undo = append(b.undo, e)
	return true
}

// CanUndo reports whether Undo would do anything.
func (b *Buffer) CanUndo() bool { return len(b.undo) > 0 }

// CanRedo reports whether Redo would do anything.
func (b *Buffer) CanRedo() bool { return len(b.redo) > 0 }
