// Package textbuffer implements the editing core of a text editor: a document
// made of lines, a set of cursors (each optionally holding a selection),
// insertion and deletion at every cursor, cursor movement with a remembered
// goal column, and undo/redo.
//
// # Model
//
// A document is a sequence of one or more lines. Lines are joined by single
// '\n' characters and the document has no trailing newline; an empty document
// is one empty line. A [Position] is a zero-based (line, column) pair, where
// the column is a byte index into the line. The package is intended for text
// without tabs or multi-byte characters, so a column is also a character
// index.
//
// A [Cursor] has a head, an optional anchor (present when [Cursor.Selected]
// is true), a primary flag and a goal column. A [Buffer] always holds at
// least one cursor, exactly one of which is primary. Cursors are kept in
// "cursor order" (ascending range start); cursors whose ranges collide are
// merged after every command.
//
// # Editing
//
// [Buffer.Insert], [Buffer.Delete] and [Buffer.DeleteForward] apply one
// replacement per cursor, in cursor order, and record a single undo entry
// for the whole command. Each replacement costs O(ℓ+m) within a line (ℓ the
// line length, m the text length), plus O(L) when lines are added or
// removed. Cursors are mapped through the composed shift of the earlier
// replacements in O(1) each, so a command costs O(C) cursor work for C
// cursors. Undo entries store replacements and cursor sets, never copies of
// the document.
//
// # Example
//
//	b := textbuffer.New("alpha\nbeta")
//	b.AddCursor(1, 0)
//	b.Insert("- ")
//	fmt.Println(b.Text()) // "- alpha\n- beta"
//	b.Undo()
//	fmt.Println(b.Text()) // "alpha\nbeta"
package textbuffer
