package textbuffer

import (
	"bytes"
	"slices"
)

type editKind int

const (
	kindInsert editKind = iota
	kindBackspace
	kindDeleteForward
)

// Insert inserts text at every cursor, replacing selections. text may
// contain '\n' to insert line breaks; it is copied. Each cursor ends after
// the text it inserted, with no selection. Inserting empty text does not
// change the document and records no undo step.
func (b *Buffer) Insert(text []byte) { b.edit(kindInsert, text) }

// InsertString is like [Buffer.Insert] for a string.
func (b *Buffer) InsertString(text string) { b.Insert([]byte(text)) }

// Delete deletes each selection or, for a cursor without one, the character
// before it (the newline before it at column 0). It is a no-op for a cursor
// at the start of the document.
func (b *Buffer) Delete() { b.edit(kindBackspace, nil) }

// DeleteForward deletes each selection or, for a cursor without one, the
// character after it (the newline after it at end of line). It is a no-op for
// a cursor at the end of the document.
func (b *Buffer) DeleteForward() { b.edit(kindDeleteForward, nil) }

// edit applies an edit command to every cursor in cursor order. Cursors not
// yet processed keep their original coordinates and are mapped into the
// current document through a composed shift, so the command is O(cursors)
// beyond the text edits themselves.
func (b *Buffer) edit(kind editKind, text []byte) {
	if kind == kindInsert && len(text) == 0 {
		// Nothing changes, but the command still resets the goal columns.
		b.finishCursorCommand()
		return
	}
	before := append(b.scratch[:0], b.cursors...)
	b.scratch = before
	reps := b.reps[:0]
	var inserted []byte // owned copy of text, shared by all replacements
	var sh shift
	d := b.doc

	for i := range b.cursors {
		c := &b.cursors[i]
		head := sh.forward(c.Head)
		s, e := head, head
		if c.HasSelection {
			anchor := sh.forward(c.Anchor)
			s, e = head, anchor
			if e.Less(s) {
				s, e = e, s
			}
		}
		var ins []byte
		switch {
		case kind == kindInsert:
			ins = text
		case c.HasSelection:
		case kind == kindBackspace:
			switch {
			case head.Col > 0:
				s = Position{head.Line, head.Col - 1}
			case head.Line > 0:
				s = Position{head.Line - 1, len(d.line(head.Line - 1))}
			}
		default:
			switch {
			case head.Col < len(d.line(head.Line)):
				e = Position{head.Line, head.Col + 1}
			case head.Line < d.lineCount()-1:
				e = Position{head.Line + 1, 0}
			}
		}
		if s == e && len(ins) == 0 {
			c.Head, c.HasSelection = head, false
			continue
		}
		var removed []byte
		if s != e {
			removed = d.extract(s, e)
		}
		if len(ins) > 0 {
			if inserted == nil {
				inserted = bytes.Clone(text)
			}
			ins = inserted
		}
		end := d.splice(s, e, ins)
		reps = append(reps, replacement{start: s, removed: removed, inserted: ins})
		sh = shift{a: sh.inverse(e), b: end}
		c.Head, c.HasSelection = end, false
	}
	b.reps = reps

	b.cursors = normalize(b.cursors)
	b.resetGoals()
	if len(reps) == 0 {
		return
	}
	b.pushUndo(entry{
		before: slices.Clone(before),
		after:  slices.Clone(b.cursors),
		reps:   slices.Clone(reps),
	})
}
