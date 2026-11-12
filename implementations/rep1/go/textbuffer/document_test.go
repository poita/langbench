package textbuffer

import (
	"strings"
	"testing"
)

func docText(d *document) string {
	ls := make([]string, len(d.lines))
	for i, l := range d.lines {
		ls[i] = string(l)
	}
	return strings.Join(ls, "\n")
}

func TestDocumentReplace(t *testing.T) {
	tests := []struct {
		name       string
		start, end Position
		text       string
		want       string
	}{
		{"insert in line", Position{1, 2}, Position{1, 2}, "XY", "abc\nbeXYta\ngamma"},
		{"replace in line", Position{0, 1}, Position{0, 3}, "-", "a-\nbeta\ngamma"},
		{"delete in line", Position{2, 0}, Position{2, 5}, "", "abc\nbeta\n"},
		{"join lines", Position{0, 3}, Position{1, 0}, "", "abcbeta\ngamma"},
		{"join across many", Position{0, 1}, Position{2, 2}, "", "amma"},
		{"split line", Position{1, 2}, Position{1, 2}, "\n", "abc\nbe\nta\ngamma"},
		{"insert two lines", Position{0, 1}, Position{0, 1}, "x\ny\nz", "ax\ny\nzbc\nbeta\ngamma"},
		{"multiline over multiline", Position{0, 2}, Position{1, 2}, "1\n2", "ab1\n2ta\ngamma"},
		{"trailing newline", Position{2, 5}, Position{2, 5}, "\n\n", "abc\nbeta\ngamma\n\n"},
		{"replace everything", Position{0, 0}, Position{2, 5}, "q", "q"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			d := newDocument([]string{"abc", "beta", "gamma"})
			removed := d.slice(tc.start, tc.end)
			d.replace(tc.start, tc.end, tc.text)
			if got := docText(d); got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
			// Reverting restores the original document.
			d.replace(tc.start, advance(tc.start, tc.text), removed)
			if got := docText(d); got != "abc\nbeta\ngamma" {
				t.Fatalf("revert gave %q", got)
			}
		})
	}
}

func TestDocumentSlice(t *testing.T) {
	d := newDocument([]string{"abc", "", "xyz"})
	for _, tc := range []struct {
		s, e Position
		want string
	}{
		{Position{0, 1}, Position{0, 1}, ""},
		{Position{0, 1}, Position{0, 3}, "bc"},
		{Position{0, 1}, Position{1, 0}, "bc\n"},
		{Position{0, 0}, Position{2, 3}, "abc\n\nxyz"},
		{Position{0, 3}, Position{2, 1}, "\n\nx"},
	} {
		if got := d.slice(tc.s, tc.e); got != tc.want {
			t.Errorf("slice(%v,%v) = %q, want %q", tc.s, tc.e, got, tc.want)
		}
	}
}

func TestDocumentLinesDoNotAlias(t *testing.T) {
	// Lines share one backing array; growing one must not clobber the next.
	d := newDocument([]string{"aa", "bb", "cc"})
	d.replace(Position{0, 1}, Position{0, 1}, "XXXX")
	d.replace(Position{1, 2}, Position{1, 2}, "YY")
	if got := docText(d); got != "aXXXXa\nbbYY\ncc" {
		t.Fatalf("got %q", got)
	}
}

func TestClampAndAdvance(t *testing.T) {
	d := newDocument([]string{"abc", "de"})
	for _, tc := range []struct {
		l, c int
		want Position
	}{
		{0, 0, Position{0, 0}},
		{0, 99, Position{0, 3}},
		{99, 99, Position{1, 2}},
		{1_000_000_000, 0, Position{1, 0}},
		{-1, -1, Position{0, 0}},
	} {
		if got := d.clamp(tc.l, tc.c); got != tc.want {
			t.Errorf("clamp(%d,%d) = %v, want %v", tc.l, tc.c, got, tc.want)
		}
	}
	if got := advance(Position{1, 2}, "ab"); got != (Position{1, 4}) {
		t.Errorf("advance single line = %v", got)
	}
	if got := advance(Position{1, 2}, "a\nbcd"); got != (Position{2, 3}) {
		t.Errorf("advance multi line = %v", got)
	}
}
