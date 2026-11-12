package textbuffer

// Cursor is a caret with an optional selection.
//
// When Selected is true, Anchor holds the other end of the selection and is
// never equal to Head; when it is false, Anchor is meaningless and the
// cursor's range is empty.
type Cursor struct {
	// Head is where the caret is.
	Head Position
	// Anchor is the fixed end of the selection; valid only if Selected.
	Anchor Position
	// Selected reports whether the cursor holds a non-empty selection.
	Selected bool
	// Primary marks the cursor that survives GoTo and ClearCursors. Exactly
	// one cursor of a Buffer is primary.
	Primary bool
	// Goal is the column that vertical movement tries to return to.
	Goal int
}

// Start returns the start of the cursor's range.
func (c Cursor) Start() Position {
	if c.Selected {
		return minPos(c.Head, c.Anchor)
	}
	return c.Head
}

// End returns the end of the cursor's range.
func (c Cursor) End() Position {
	if c.Selected {
		return maxPos(c.Head, c.Anchor)
	}
	return c.Head
}

// Backward reports whether the cursor has a selection whose head is at its
// start.
func (c Cursor) Backward() bool {
	return c.Selected && c.Head.Less(c.Anchor)
}

// compareRanges orders cursors by ascending range start and, for equal
// starts, by descending range end.
func compareRanges(a, b Cursor) int {
	if d := a.Start().Compare(b.Start()); d != 0 {
		return d
	}
	return b.End().Compare(a.End())
}
