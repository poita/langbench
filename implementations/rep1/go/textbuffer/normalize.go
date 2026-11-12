package textbuffer

import "slices"

// normalize sorts cursors into cursor order and merges those whose ranges
// collide. The sort is stable, so cursors with identical ranges keep their
// relative order and the merged cursor keeps the goal column of the first. It
// works in place and returns the shortened slice.
func normalize(cs []Cursor) []Cursor {
	if len(cs) < 2 {
		return cs
	}
	if !slices.IsSortedFunc(cs, compareRanges) {
		slices.SortStableFunc(cs, compareRanges)
	}
	w := 0
	cur := cs[0]
	for _, c := range cs[1:] {
		var join bool
		if cur.Selected && c.Selected {
			// Selections that merely touch do not merge.
			join = c.Start().Less(cur.End())
		} else {
			join = !cur.End().Less(c.Start())
		}
		if join {
			cur = mergeCursors(cur, c)
		} else {
			cs[w] = cur
			w++
			cur = c
		}
	}
	cs[w] = cur
	return cs[:w+1]
}

// mergeCursors combines cur (first in sorted order) with c, which collides
// with it.
func mergeCursors(cur, c Cursor) Cursor {
	start := cur.Start()
	end := maxPos(cur.End(), c.End())
	out := cur
	out.Primary = cur.Primary || c.Primary
	switch {
	case start == end:
		out.Selected = false
		out.Head = start
	case cur.Backward():
		out.Selected = true
		out.Head, out.Anchor = start, end
	default:
		out.Selected = true
		out.Head, out.Anchor = end, start
	}
	return out
}
