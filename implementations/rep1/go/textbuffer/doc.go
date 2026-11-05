// Package textbuffer implements the editing core of a text editor: a document
// made of lines, a set of cursors (each optionally holding a selection),
// insertion and deletion at every cursor, cursor movement with a remembered
// goal column, and undo/redo.
//
// A [Buffer] holds the document and the cursors. All positions are
// (line, column) pairs, 0-based; a column is a byte index into the line.
// Lines are expected to contain printable ASCII only, so bytes and
// characters coincide.
//
// # Cursors
//
// Cursors are kept in cursor order (ascending range start). After every
// mutating operation colliding cursors are merged, so the starts of the
// cursors of a buffer are always distinct. Exactly one cursor is primary.
//
// # Editing and history
//
// [Buffer.Insert], [Buffer.Delete] and [Buffer.DeleteForward] edit at every
// cursor. Each one that changes the document is a single undo step, however
// many cursors took part; [Buffer.Undo] and [Buffer.Redo] walk those steps.
//
// # Internals
//
// The document is a gap buffer of mutable line buffers (see lineStore), so a
// multi-cursor edit that adds or removes lines moves each line slot at most
// once. Multi-cursor edits map not-yet-processed cursors into the edited
// document with a composed shift (see shift), making them linear in the
// number of cursors.
package textbuffer
