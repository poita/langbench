package textbuffer

// replacement records one splice of the document: Removed was replaced by
// Inserted starting at Start, a position in the document as it was
// immediately before this replacement was applied.
type replacement struct {
	Start    Position
	Removed  string
	Inserted string
}

// entry is one undo step: an edit command. before and after are the cursor
// sets (as normalized) around the command; they are never mutated once
// stored.
type entry struct {
	before, after []Cursor
	reps          []replacement
}

// applyForward re-applies the entry's replacements in order.
func (e *entry) applyForward(d *document) {
	for _, r := range e.reps {
		d.replace(r.Start, advance(r.Start, r.Removed), r.Inserted)
	}
}

// applyBackward reverts the entry's replacements in reverse order.
func (e *entry) applyBackward(d *document) {
	for i := len(e.reps) - 1; i >= 0; i-- {
		r := e.reps[i]
		d.replace(r.Start, advance(r.Start, r.Inserted), r.Removed)
	}
}
