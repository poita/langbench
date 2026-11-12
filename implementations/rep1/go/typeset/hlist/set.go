package hlist

import (
	"typeset/dim"
	"typeset/metric"
)

// Run is a positioned piece of text on a line.
type Run struct {
	Face  *metric.Face
	Size  int64
	Raise int64
	X     int64 // left edge
	Width int64
	Text  string
	frag  int
}

// Line is a set line: positioned runs plus its vertical metrics.
type Line struct {
	Runs       []Run
	Ascent     int64
	Depth      int64
	Width      int64 // the set width W_set
	StartX     int64 // x of the first item
	Notes      []int // footnotes referenced, in order
	Overfull   bool
	Hyphenated bool // ends at a breakpoint with non-empty pre-break text
}

// End returns the x coordinate after the last item of the line.
func (ln *Line) End() int64 { return ln.StartX + ln.Width }

// SetLines sets the lines of l broken at the given breakpoints (the final
// breakpoint last).
func SetLines(env *Env, l *List, breaks []int, geo Geometry) []*Line {
	lines := make([]*Line, 0, len(breaks))
	a := 0
	for k, b := range breaks {
		lines = append(lines, setLine(env, l, a, b, geo, k == 0))
		a = b
	}
	return lines
}

func setLine(env *Env, l *List, a, b int, geo Geometry, firstLine bool) *Line {
	p := l.prep()
	s := l.first(p, a, b)
	m := l.Line(a, b)
	measure := geo.Measure
	left := geo.Left
	if firstLine {
		measure -= geo.FirstIndent
		left += geo.FirstIndent
	}

	// Glue widths.
	items := l.Items[s:b]
	widths := make([]int64, len(items))
	for i := range items {
		switch items[i].Kind {
		case Box:
			widths[i] = items[i].Width
		case Glue:
			widths[i] = items[i].W
		}
	}
	if !m.Inf && l.Ctx.Align == Justify {
		E := measure - m.W
		var weights func(*Item) int64
		var T int64
		full := false
		switch {
		case E == 0, E > 0 && m.Y == 0, E < 0 && m.Z == 0:
		case E > 0:
			weights, T = func(it *Item) int64 { return it.Y }, m.Y
		case -E <= m.Z:
			weights, T = func(it *Item) int64 { return it.Z }, m.Z
		default:
			full = true
		}
		if full {
			for i := range items {
				if items[i].Kind == Glue {
					widths[i] = items[i].W - items[i].Z
				}
			}
		} else if weights != nil {
			var P, prevC int64
			for i := range items {
				if items[i].Kind != Glue {
					continue
				}
				P += weights(&items[i])
				C := dim.FloorDiv(E*P, T)
				widths[i] = items[i].W + (C - prevC)
				prevC = C
			}
		}
	}

	// W_set.
	var wset int64
	for _, w := range widths {
		wset += w
	}
	var pre *Item
	if it := &l.Items[b]; it.Kind == Penalty && it.Pre != nil {
		pre = it.Pre
		wset += pre.Width
	}

	ln := &Line{Width: wset, Overfull: wset > measure, Hyphenated: pre != nil}
	switch l.Ctx.Align {
	case Right:
		ln.StartX = left + measure - wset
	case Center:
		ln.StartX = left + dim.FloorDiv(measure-wset, 2)
	default:
		ln.StartX = left
	}

	x := ln.StartX
	contig := false // the previous emitted item was a text box of lastFrag
	lastFrag := 0
	haveBox := false
	emit := func(it *Item, w int64) {
		haveBox = true
		if v := dim.Scale(it.Face.Ascent, it.Size) + it.Raise; v > ln.Ascent {
			ln.Ascent = v
		}
		if d := dim.Scale(it.Face.Descent, it.Size) - it.Raise; d > ln.Depth {
			ln.Depth = d
		}
		if it.Note > 0 {
			ln.Notes = append(ln.Notes, it.Note)
		}
		if contig && it.Frag == lastFrag {
			r := &ln.Runs[len(ln.Runs)-1]
			r.Text += it.Text
			r.Width += w
		} else {
			ln.Runs = append(ln.Runs, Run{
				Face: it.Face, Size: it.Size, Raise: it.Raise,
				X: x, Width: w, Text: it.Text, frag: it.Frag,
			})
		}
		contig, lastFrag = true, it.Frag
		x += w
	}
	for i := range items {
		it := &items[i]
		switch it.Kind {
		case Box:
			if it.Rigid {
				contig = false
				x += widths[i]
				continue
			}
			emit(it, widths[i])
		case Glue:
			contig = false
			x += widths[i]
		}
	}
	if pre != nil {
		emit(pre, pre.Width)
	}
	if !haveBox {
		f := env.Faces.Face(l.Ctx.Style)
		ln.Ascent = dim.Scale(f.Ascent, l.Ctx.Size)
		ln.Depth = dim.Scale(f.Descent, l.Ctx.Size)
	}
	return ln
}
