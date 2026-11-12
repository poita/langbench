// Package hlist builds horizontal lists (boxes, glue and penalties) from
// resolved inline text, and sets broken lines into positioned runs.
package hlist

import (
	"typeset/metric"
)

// Kind is the kind of a horizontal list item.
type Kind uint8

// Item kinds.
const (
	Box Kind = iota
	Glue
	Penalty
)

// Item is one element of a horizontal list.
type Item struct {
	Kind Kind

	// Box fields. A rigid box has no Face and no Text.
	Face  *metric.Face
	Size  int64
	Raise int64
	Text  string
	Width int64
	Frag  int  // fragment identity, used to merge output runs
	Rigid bool // a rigid box emits nothing and has no vertical extent
	Note  int  // footnote number, for a reference mark box

	// Glue fields.
	W, Y, Z  int64
	Infinite bool

	// Penalty fields.
	P       int64
	Flagged bool
	Pre     *Item // pre-break text, a Box, or nil
}

// Align is a line alignment.
type Align uint8

// Alignments.
const (
	Justify Align = iota
	Left
	Right
	Center
)

// ParseAlign converts a setting value to an Align.
func ParseAlign(s string) Align {
	switch s {
	case "left":
		return Left
	case "right":
		return Right
	case "center":
		return Center
	}
	return Justify
}

// Context holds the style-related parts of a list's context. The geometry
// (left, measure, first-indent) is supplied separately when the list is
// broken.
type Context struct {
	Style     metric.Style
	Size      int64
	Align     Align
	Hyphenate bool
}

// Geometry is where a list's lines go.
type Geometry struct {
	Left, Measure, FirstIndent int64
}

// List is a built horizontal list.
type List struct {
	Items []Item
	Ctx   Context

	pre *prefix
}

type prefix struct {
	w, y, z []int64
	inf     []int32
	skip    []int32 // skip[i] = first index >= i that is not a Glue
}

func (l *List) prep() *prefix {
	if l.pre != nil {
		return l.pre
	}
	n := len(l.Items)
	p := &prefix{
		w: make([]int64, n+1), y: make([]int64, n+1), z: make([]int64, n+1),
		inf: make([]int32, n+1), skip: make([]int32, n+2),
	}
	for i, it := range l.Items {
		p.w[i+1], p.y[i+1], p.z[i+1], p.inf[i+1] = p.w[i], p.y[i], p.z[i], p.inf[i]
		switch it.Kind {
		case Box:
			p.w[i+1] += it.Width
		case Glue:
			p.w[i+1] += it.W
			p.y[i+1] += it.Y
			p.z[i+1] += it.Z
			if it.Infinite {
				p.inf[i+1]++
			}
		}
	}
	p.skip[n] = int32(n)
	p.skip[n+1] = int32(n)
	for i := n - 1; i >= 0; i-- {
		if l.Items[i].Kind == Glue {
			p.skip[i] = p.skip[i+1]
		} else {
			p.skip[i] = int32(i)
		}
	}
	l.pre = p
	return p
}

// Final returns the index of the final breakpoint.
func (l *List) Final() int { return len(l.Items) - 1 }

// Breakpoints returns the breakpoint indices in increasing order, starting
// with breakpoint 0 (the notional start of the list).
func (l *List) Breakpoints() []int {
	bp := []int{0}
	for i, it := range l.Items {
		switch it.Kind {
		case Glue:
			if i > 0 && l.Items[i-1].Kind == Box {
				bp = append(bp, i)
			}
		case Penalty:
			if it.P < 10000 {
				bp = append(bp, i)
			}
		}
	}
	return bp
}

// Penalty returns the penalty and flag of breakpoint b.
func (l *List) Penalty(b int) (int64, bool) {
	if b == 0 {
		return 0, false
	}
	it := &l.Items[b]
	if it.Kind == Penalty {
		return it.P, it.Flagged
	}
	return 0, false
}

// LineMeasure holds the natural width, stretch and shrink of a line.
type LineMeasure struct {
	W, Y, Z int64
	Inf     bool
	// W0 is W without the pre-break text of the ending breakpoint.
	W0 int64
}

// first returns the index of the first item of a line starting at
// breakpoint a and ending at breakpoint b, after leading glue is removed.
func (l *List) first(p *prefix, a, b int) int {
	s := a + 1
	if a == 0 {
		s = 0
	}
	s = int(p.skip[s])
	if s > b {
		s = b
	}
	return s
}

// Line measures the line between breakpoints a < b in O(1).
func (l *List) Line(a, b int) LineMeasure {
	p := l.prep()
	s := l.first(p, a, b)
	m := LineMeasure{
		W0:  p.w[b] - p.w[s],
		Y:   p.y[b] - p.y[s],
		Z:   p.z[b] - p.z[s],
		Inf: p.inf[b]-p.inf[s] > 0,
	}
	m.W = m.W0
	if it := &l.Items[b]; it.Kind == Penalty && it.Pre != nil {
		m.W += it.Pre.Width
	}
	return m
}

// Natural returns the natural width of the whole list on one line,
// excluding the final infinite glue.
func (l *List) Natural() int64 {
	p := l.prep()
	return p.w[len(l.Items)]
}
