package textbuffer

import (
	"slices"
)

// Cursor is a caret with an optional selection.
type Cursor struct {
	// Head is where the caret is.
	Head Position
	// Anchor is the other end of the selection; it is meaningful only when
	// HasSelection is true, and then it never equals Head.
	Anchor       Position
	HasSelection bool
	// Primary marks the one primary cursor of a buffer.
	Primary bool
	// Goal is the column used by vertical movement.
	Goal int
}

// Start returns the start of the cursor's range.
func (c Cursor) Start() Position {
	if c.HasSelection && c.Anchor.Less(c.Head) {
		return c.Anchor
	}
	return c.Head
}

// End returns the end of the cursor's range.
func (c Cursor) End() Position {
	if c.HasSelection && c.Head.Less(c.Anchor) {
		return c.Anchor
	}
	return c.Head
}

// Range returns the start and end of the cursor's range; for a cursor
// without a selection both are the head.
func (c Cursor) Range() (start, end Position) { return c.Start(), c.End() }

// backward reports whether the head is at the start of a selection.
func (c Cursor) backward() bool { return c.HasSelection && c.Head.Less(c.Anchor) }

// compareCursors is the cursor order: start ascending, end descending.
func compareCursors(a, b Cursor) int {
	if r := a.Start().Compare(b.Start()); r != 0 {
		return r
	}
	return b.End().Compare(a.End())
}

// normalize sorts cs into cursor order and merges colliding cursors. It works
// in place and returns the shortened slice.
func normalize(cs []Cursor) []Cursor {
	if !slices.IsSortedFunc(cs, compareCursors) {
		slices.SortStableFunc(cs, compareCursors)
	}
	out := 0 // cs[out] is the current group's merged cursor
	for i := 1; i < len(cs); i++ {
		cur, c := &cs[out], cs[i]
		curEnd := cur.End()
		cStart := c.Start()
		var joins bool
		if cur.HasSelection && c.HasSelection {
			joins = cStart.Less(curEnd)
		} else {
			joins = cStart.Compare(curEnd) <= 0
		}
		if !joins {
			out++
			cs[out] = c
			continue
		}
		start, end := cur.Start(), curEnd
		if e := c.End(); end.Less(e) {
			end = e
		}
		switch {
		case start == end:
			cur.HasSelection = false
			cur.Head = start
		case cur.backward():
			cur.Head, cur.Anchor, cur.HasSelection = start, end, true
		default:
			cur.Head, cur.Anchor, cur.HasSelection = end, start, true
		}
		cur.Primary = cur.Primary || c.Primary
	}
	return cs[:out+1]
}
