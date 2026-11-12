package layout

import "testing"

func items(kinds ...vkind) []vitem {
	out := make([]vitem, len(kinds))
	for i, k := range kinds {
		out[i] = vitem{kind: k}
	}
	return out
}

func lines(n int, heading bool) []vitem {
	out := make([]vitem, n)
	for i := range out {
		out[i] = vitem{kind: vLine, k: i + 1, n: n, heading: heading}
	}
	return out
}

func TestWidowsAndOrphans(t *testing.T) {
	it := lines(4, false)
	legal := computeLegal(it, 2, 2, true)
	// only the break before line 3 leaves two lines on each side.
	want := []bool{false, false, true, false, true}
	for j, w := range want {
		if legal[j] != w {
			t.Errorf("legal[%d] = %v, want %v", j, legal[j], w)
		}
	}
	if legal = computeLegal(it, 1, 1, true); !legal[1] || !legal[2] || !legal[3] || !legal[4] {
		t.Errorf("widows=orphans=1 should allow every break: %v", legal)
	}
}

func TestKeepWithNext(t *testing.T) {
	var it []vitem
	it = append(it, lines(3, false)...)
	it = append(it, items(vGlue)...)
	it = append(it, lines(2, true)...)
	it = append(it, items(vGlue, vFloat)...)
	it = append(it, lines(3, false)...)
	legal := computeLegal(it, 2, 2, true)
	if !legal[4] {
		t.Error("break before the heading should be legal")
	}
	// positions: 5 (heading line 2), 6 (glue), 7 (float), 8 (next paragraph), 9 (its line 2)
	for _, j := range []int{5, 6, 7, 8, 9} {
		if legal[j] {
			t.Errorf("position %d should be illegal", j)
		}
	}
	off := computeLegal(it, 2, 2, false)
	if !off[6] || !off[7] || !off[8] {
		t.Error("keep-with-next off should allow breaks after a heading")
	}
	if !legal[len(it)] {
		t.Error("the end of the list is always a legal break")
	}
}

func TestVstate(t *testing.T) {
	st := newVstate(20000)
	if b := st.line(12000, 1000, 7310, 2230); b != 27310 {
		t.Errorf("first baseline %d", b)
	}
	if b := st.line(12000, 1000, 7310, 2230); b != 39310 {
		t.Errorf("second baseline %d", b)
	}
	st.skip(6000)
	if b := st.line(12000, 1000, 7310, 2230); b != 39310+2230+6000+7310 {
		t.Errorf("after glue %d", b)
	}
}

func TestVbuilderSpacing(t *testing.T) {
	v := &vbuilder{}
	line := []vitem{{kind: vLine}}
	v.leaf(6000, 6000, line) // not started: no glue
	v.vspace(12000)
	v.leaf(6000, 6000, line)
	if len(v.items) != 3 || v.items[1].kind != vGlue || v.items[1].h != 18000 {
		t.Errorf("items %+v", v.items)
	}
	v.enter(3000)
	v.leaf(0, 0, line)
	if g := v.items[3]; g.kind != vGlue || g.h != 6000 {
		t.Errorf("max of space-after and container space: %+v", g)
	}
}

func TestMarkerText(t *testing.T) {
	cases := []struct {
		ordered bool
		depth   int
		n       int
		want    string
	}{
		{false, 1, 1, "•"}, {false, 2, 1, "–"}, {false, 3, 1, "*"}, {false, 4, 1, "•"},
		{true, 1, 12, "12."}, {true, 2, 28, "ab."}, {true, 3, 14, "xiv."},
	}
	for _, c := range cases {
		if got := markerText(c.ordered, c.depth, c.n); got != c.want {
			t.Errorf("markerText(%v,%d,%d) = %q, want %q", c.ordered, c.depth, c.n, got, c.want)
		}
	}
}
