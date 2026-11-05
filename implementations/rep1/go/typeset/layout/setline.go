package layout

import (
	"typeset/metrics"
	"typeset/settings"
	"typeset/units"
)

// Run is a placed run of text on a line. X is absolute; Raise lifts the
// run above its line's baseline.
type Run struct {
	Text  string
	Face  int
	Size  int64
	X, W  int64
	Raise int64
}

// Line is one set line. Runs hold the text of the list; Extra holds runs
// that share the line's baseline but are not part of the list (list markers,
// TOC leaders and page labels).
type Line struct {
	Runs          []Run
	Extra         []Run
	Ascent, Depth int64
	Leading       int64
	Fns           []int32 // footnotes referenced, in order
	EndX          int64
}

// BreakAndSet breaks a list into lines, sets them, and adds the list to the
// document statistics.
func (e *Env) BreakAndSet(hl *HList) []*Line {
	br := e.BreakList(hl)
	e.Stats.TotalDemerits += br.Total
	if br.Emergency {
		e.Stats.EmergencyLists++
	}
	return e.SetLines(hl, br)
}

// SetLines sets the lines of a broken list.
func (e *Env) SetLines(hl *HList, br Breaking) []*Line {
	ctx := &hl.Ctx
	lines := make([]*Line, 0, len(br.Breaks))
	a := int32(-1)
	for _, b := range br.Breaks {
		s := hl.start(a)
		L := ctx.Measure
		leftLine := ctx.Left
		if a < 0 {
			L -= ctx.FirstIndent
			leftLine += ctx.FirstIndent
		}
		w, y, z, inf := hl.lineSums(a, b, false)
		pen := &hl.Items[b]
		var pre int64
		if pen.Kind == IPenalty && pen.Text != "" {
			pre = pen.W
			e.Stats.HyphenatedLines++
		}
		W := w + pre
		// glue treatment
		mode := 0 // 0 natural, 1 stretch, 2 shrink, 3 full shrink
		var T int64
		var E int64
		if !inf && ctx.Align == settings.Justify {
			E = L - W
			switch {
			case E == 0 || E > 0 && y == 0 || E < 0 && z == 0:
			case E > 0:
				mode, T = 1, y
			case -E <= z:
				mode, T = 2, z
			default:
				mode = 3
			}
		}
		// set widths and total
		var wset int64
		var P, Cprev int64
		type placed struct {
			it *Item
			w  int64
		}
		var asc, dep int64
		haveBox := false
		ln := &Line{Leading: ctx.Leading}
		var items []placed
		for i := s; i < b; i++ {
			it := &hl.Items[i]
			sw := it.W
			if it.Kind == IGlue {
				switch mode {
				case 1:
					P += it.Y
					C := units.FloorDiv(E*P, T)
					sw += C - Cprev
					Cprev = C
				case 2:
					P += it.Z
					C := units.FloorDiv(E*P, T)
					sw += C - Cprev
					Cprev = C
				case 3:
					sw -= it.Z
				}
				if it.Flag {
					sw = 0
				}
			} else if it.Kind == IPenalty {
				continue
			}
			wset += sw
			items = append(items, placed{it, sw})
		}
		if pre > 0 {
			wset += pre
		}
		var x int64
		switch ctx.Align {
		case settings.Right:
			x = leftLine + L - wset
		case settings.Center:
			x = leftLine + units.FloorDiv(L-wset, 2)
		default:
			x = leftLine
		}
		if wset > L {
			e.Stats.OverfullLines++
		}
		canMerge := false
		lastIdx := -1
		var lastFrag int32
		addText := func(it *Item, text string, wd int64) {
			if last := lastIdx; canMerge && last >= 0 && lastFrag == it.Frag && ln.Runs[last].Face == int(it.Face) &&
				ln.Runs[last].Size == it.Size && ln.Runs[last].Raise == it.Raise {
				ln.Runs[last].Text += text
				ln.Runs[last].W += wd
			} else {
				ln.Runs = append(ln.Runs, Run{Text: text, Face: int(it.Face), Size: it.Size, X: x, W: wd, Raise: it.Raise})
				lastIdx = len(ln.Runs) - 1
				lastFrag = it.Frag
			}
			canMerge = true
			x += wd
		}
		metricsOf := func(it *Item) {
			f := e.face(int(it.Face))
			a := units.Scale(f.Ascent, it.Size) + it.Raise
			d := units.Scale(f.Descent, it.Size) - it.Raise
			if d < 0 {
				d = 0
			}
			if !haveBox || a > asc {
				asc = a
			}
			if !haveBox || d > dep {
				dep = d
			}
			haveBox = true
		}
		for _, p := range items {
			it := p.it
			switch it.Kind {
			case IBox:
				if it.Flag {
					canMerge = false
					x += p.w
					continue
				}
				if it.Fn > 0 {
					ln.Fns = append(ln.Fns, it.Fn)
				}
				metricsOf(it)
				addText(it, it.Text, p.w)
			case IGlue:
				canMerge = false
				x += p.w
			}
		}
		if pre > 0 {
			metricsOf(pen)
			addText(pen, pen.Text, pre)
		}
		if !haveBox {
			f := e.face(metrics.FaceIndex(ctx.Family, ctx.Bold, ctx.Italic))
			asc, dep = units.Scale(f.Ascent, ctx.Size), units.Scale(f.Descent, ctx.Size)
		}
		ln.Ascent, ln.Depth, ln.EndX = asc, dep, x
		lines = append(lines, ln)
		a = b
	}
	e.Stats.Lines += len(lines)
	return lines
}

// PreLine sets one line of preformatted text as a single box.
func (e *Env) PreLine(text string, ctx Context) *Line {
	face := metrics.FaceIndex(ctx.Family, false, false)
	f := e.face(face)
	ln := &Line{Leading: ctx.Leading, Ascent: units.Scale(f.Ascent, ctx.Size), Depth: units.Scale(f.Descent, ctx.Size)}
	x := ctx.Left
	if text != "" {
		w := e.textWidth(face, ctx.Size, []rune(text))
		ln.Runs = append(ln.Runs, Run{Text: text, Face: face, Size: ctx.Size, X: x, W: w})
		x += w
		if w > ctx.Measure {
			e.Stats.OverfullLines++
		}
	}
	ln.EndX = x
	e.Stats.Lines++
	return ln
}
