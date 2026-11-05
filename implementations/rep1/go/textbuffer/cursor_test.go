package textbuffer

import (
	"slices"
	"testing"
)

func pt(l, c int) Position { return Position{l, c} }

func point(l, c int) Cursor { return Cursor{Head: pt(l, c)} }

func sel(head, anchor Position) Cursor {
	return Cursor{Head: head, Anchor: anchor, HasSelection: true}
}

func TestCursorRange(t *testing.T) {
	fw := sel(pt(1, 4), pt(0, 2))
	bw := sel(pt(0, 2), pt(1, 4))
	for _, c := range []Cursor{fw, bw} {
		s, e := c.Range()
		if s != pt(0, 2) || e != pt(1, 4) {
			t.Errorf("range of %+v = %v %v", c, s, e)
		}
	}
	if !bw.backward() || fw.backward() || point(0, 0).backward() {
		t.Error("backward() wrong")
	}
	s, e := point(2, 3).Range()
	if s != pt(2, 3) || e != pt(2, 3) {
		t.Error("empty range wrong")
	}
}

func TestNormalize(t *testing.T) {
	prim := func(c Cursor) Cursor { c.Primary = true; return c }
	goal := func(c Cursor, g int) Cursor { c.Goal = g; return c }
	tests := []struct {
		name string
		in   []Cursor
		want []Cursor
	}{
		{"sorted untouched", []Cursor{point(0, 1), point(0, 3), point(2, 0)},
			[]Cursor{point(0, 1), point(0, 3), point(2, 0)}},
		{"sorts", []Cursor{point(2, 0), point(0, 3), point(0, 1)},
			[]Cursor{point(0, 1), point(0, 3), point(2, 0)}},
		{"equal points merge, primary wins", []Cursor{point(1, 1), prim(point(1, 1))},
			[]Cursor{prim(point(1, 1))}},
		{"first goal kept on equal ranges", []Cursor{goal(point(1, 1), 5), goal(point(1, 1), 9)},
			[]Cursor{goal(point(1, 1), 5)}},
		{"point inside selection", []Cursor{sel(pt(0, 5), pt(0, 1)), point(0, 3)},
			[]Cursor{sel(pt(0, 5), pt(0, 1))}},
		{"point on selection edge", []Cursor{sel(pt(0, 5), pt(0, 1)), point(0, 5)},
			[]Cursor{sel(pt(0, 5), pt(0, 1))}},
		{"point at selection start", []Cursor{point(0, 1), sel(pt(0, 5), pt(0, 1))},
			[]Cursor{sel(pt(0, 5), pt(0, 1))}},
		{"touching selections stay apart",
			[]Cursor{sel(pt(0, 3), pt(0, 1)), sel(pt(0, 5), pt(0, 3))},
			[]Cursor{sel(pt(0, 3), pt(0, 1)), sel(pt(0, 5), pt(0, 3))}},
		{"overlapping selections union, first direction",
			[]Cursor{sel(pt(0, 1), pt(0, 4)), sel(pt(0, 6), pt(0, 3))},
			[]Cursor{sel(pt(0, 1), pt(0, 6))}},
		{"forward direction kept",
			[]Cursor{sel(pt(0, 4), pt(0, 1)), sel(pt(0, 3), pt(0, 6))},
			[]Cursor{sel(pt(0, 6), pt(0, 1))}},
		{"nested selection absorbed",
			[]Cursor{sel(pt(0, 2), pt(0, 3)), sel(pt(0, 9), pt(0, 1))},
			[]Cursor{sel(pt(0, 9), pt(0, 1))}},
		{"chain merges transitively",
			[]Cursor{point(0, 1), sel(pt(0, 4), pt(0, 1)), point(0, 4)},
			[]Cursor{sel(pt(0, 4), pt(0, 1))}},
	}
	for _, tc := range tests {
		got := normalize(slices.Clone(tc.in))
		if !slices.Equal(got, tc.want) {
			t.Errorf("%s:\n got  %+v\n want %+v", tc.name, got, tc.want)
		}
	}
}
