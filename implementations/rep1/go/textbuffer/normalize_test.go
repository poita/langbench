package textbuffer

import (
	"reflect"
	"testing"
)

func pt(l, c int) Position { return Position{l, c} }

func point(l, c, goal int) Cursor { return Cursor{Head: pt(l, c), Goal: goal} }

func sel(head, anchor Position, goal int) Cursor {
	return Cursor{Head: head, Anchor: anchor, Selected: true, Goal: goal}
}

func TestNormalize(t *testing.T) {
	prim := func(c Cursor) Cursor { c.Primary = true; return c }
	tests := []struct {
		name string
		in   []Cursor
		want []Cursor
	}{
		{"sorted untouched", []Cursor{prim(point(0, 1, 0)), point(1, 0, 0)}, []Cursor{prim(point(0, 1, 0)), point(1, 0, 0)}},
		{"sorted by start", []Cursor{point(2, 0, 0), prim(point(0, 0, 0))}, []Cursor{prim(point(0, 0, 0)), point(2, 0, 0)}},
		{"equal points merge, first goal wins", []Cursor{point(0, 2, 7), prim(point(0, 2, 9))}, []Cursor{prim(point(0, 2, 7))}},
		{"point inside selection", []Cursor{sel(pt(0, 5), pt(0, 1), 5), point(0, 3, 3)}, []Cursor{sel(pt(0, 5), pt(0, 1), 5)}},
		{"point at selection edge", []Cursor{sel(pt(0, 5), pt(0, 1), 5), point(0, 5, 3)}, []Cursor{sel(pt(0, 5), pt(0, 1), 5)}},
		{"touching selections stay apart", []Cursor{sel(pt(0, 3), pt(0, 1), 3), sel(pt(0, 5), pt(0, 3), 5)}, []Cursor{sel(pt(0, 3), pt(0, 1), 3), sel(pt(0, 5), pt(0, 3), 5)}},
		{"overlapping selections merge, direction of first", []Cursor{sel(pt(0, 1), pt(0, 4), 1), sel(pt(0, 6), pt(0, 3), 6)}, []Cursor{sel(pt(0, 1), pt(0, 6), 1)}},
		{"forward first keeps forward", []Cursor{sel(pt(0, 4), pt(0, 1), 4), sel(pt(0, 3), pt(0, 6), 3)}, []Cursor{sel(pt(0, 6), pt(0, 1), 4)}},
		{"equal start, larger selection first", []Cursor{point(0, 1, 1), sel(pt(0, 4), pt(0, 1), 4)}, []Cursor{sel(pt(0, 4), pt(0, 1), 4)}},
		{"primary survives merge", []Cursor{prim(point(0, 1, 1)), point(0, 1, 1)}, []Cursor{prim(point(0, 1, 1))}},
		{"chain of merges", []Cursor{point(0, 1, 0), sel(pt(0, 4), pt(0, 1), 0), point(0, 4, 0), point(0, 5, 0)}, []Cursor{sel(pt(0, 4), pt(0, 1), 0), point(0, 5, 0)}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := normalize(append([]Cursor(nil), tc.in...))
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got  %+v\nwant %+v", got, tc.want)
			}
		})
	}
}
