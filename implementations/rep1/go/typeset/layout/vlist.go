package layout

import (
	"strconv"

	"typeset/markup"
	"typeset/metrics"
	"typeset/units"
)

// VKind tags a vertical item.
type VKind uint8

// Vertical item kinds.
const (
	VLine VKind = iota
	VGlue
	VRule
	VRow
	VFloat
	VForce
)

// RowLine is one line of a table cell; Off is its baseline offset from the
// top of the row.
type RowLine struct {
	Line *Line
	Off  int64
}

// VItem is one item of a vertical list.
type VItem struct {
	Kind    VKind
	H       int64 // glue height, rule thickness, row height
	X, W    int64 // rule position and width
	Line    *Line
	Group   int32
	K, N    int32 // 1-based index of the line in its group, and group size
	Heading bool
	Row     [][]RowLine
	Fig     int32
}

// HeadingRec records a heading for the table of contents and the running
// headers. Item is the index of its first line in the vertical list.
type HeadingRec struct {
	Level  int
	Star   bool
	Number string // empty when unnumbered
	Plain  string
	Item   int
}

// walker converts a block tree into a flat vertical list, applying the
// inter-block space rules.
type walker struct {
	e        *Env
	items    []VItem
	pm, pa   int64
	started  bool
	group    int32
	counters [4]int
	headings []HeadingRec
}

func (w *walker) push(it VItem) { w.items = append(w.items, it) }

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func clampMeasure(m int64) int64 {
	if m < 1000 {
		return 1000
	}
	return m
}

// leaf applies the space rules around a leaf block and emits its items.
func (w *walker) leaf(before, after int64, emit func()) {
	w.pm = max64(w.pm, before)
	if w.started && w.pm+w.pa > 0 {
		w.push(VItem{Kind: VGlue, H: w.pm + w.pa})
	}
	w.pm, w.pa = after, 0
	emit()
	w.started = true
}

// emitLines appends the lines of one horizontal list as one group.
func (w *walker) emitLines(lines []*Line, heading bool) {
	w.group++
	for i, ln := range lines {
		w.push(VItem{Kind: VLine, Line: ln, Group: w.group, K: int32(i + 1), N: int32(len(lines)), Heading: heading})
	}
}

func (w *walker) blocks(bs []markup.Block, ctx Context, depth int) {
	for _, b := range bs {
		w.block(b, ctx, depth)
	}
}

func (w *walker) block(b markup.Block, ctx Context, depth int) {
	e, S := w.e, w.e.S
	switch b := b.(type) {
	case *markup.Paragraph:
		w.leaf(S.ParSpace, S.ParSpace, func() {
			c := ctx
			c.FirstIndent = S.ParIndent
			w.emitLines(e.BreakAndSet(e.BuildList(b.Text, c)), false)
		})
	case *markup.Heading:
		w.heading(b, ctx)
	case *markup.Quote:
		w.pm = max64(w.pm, S.QuoteSpace)
		c := ctx
		c.Left += S.QuoteIndent
		c.Measure = clampMeasure(c.Measure - 2*S.QuoteIndent)
		w.blocks(b.Children, c, depth)
		w.pm = max64(w.pm, S.QuoteSpace)
	case *markup.Group:
		c := ctx
		if b.Align != nil {
			c.Align = *b.Align
		}
		if b.Size != nil {
			c.Size = *b.Size
		}
		if b.Leading != nil {
			c.Leading = *b.Leading
		}
		if b.Font != nil {
			c.Family = *b.Font
		}
		var ind, rind int64
		if b.Indent != nil {
			ind = *b.Indent
		}
		if b.RightIndent != nil {
			rind = *b.RightIndent
		}
		c.Left += ind
		c.Measure = clampMeasure(c.Measure - ind - rind)
		w.blocks(b.Children, c, depth)
	case *markup.List:
		w.list(b, ctx, depth+1)
	case *markup.Table:
		w.leaf(S.TableSpace, S.TableSpace, func() { w.table(b, ctx) })
	case *markup.Pre:
		w.leaf(S.PreSpace, S.PreSpace, func() {
			c := ctx
			c.Family, c.Bold, c.Italic = S.PreFont, false, false
			c.Size, c.Leading = S.PreSize, S.PreLeading
			c.Left += S.PreIndent
			c.Measure = clampMeasure(c.Measure - S.PreIndent)
			var lines []*Line
			for _, l := range b.Lines {
				lines = append(lines, e.PreLine(l, c))
			}
			w.emitLines(lines, false)
		})
	case *markup.Figure:
		idx := len(e.figs)
		e.layoutFigure(b, idx+1)
		w.leaf(0, 0, func() { w.push(VItem{Kind: VFloat, Fig: int32(idx)}) })
	case *markup.Rule:
		w.leaf(S.RuleSpace, S.RuleSpace, func() {
			w.push(VItem{Kind: VRule, X: ctx.Left, W: ctx.Measure, H: S.RuleThickness})
		})
	case *markup.VSpace:
		w.pa += b.Height
	case *markup.NewPage:
		w.push(VItem{Kind: VForce})
		w.pm, w.pa = 0, 0
	}
}

func (w *walker) heading(h *markup.Heading, ctx Context) {
	e, S := w.e, w.e.S
	l := h.Level - 1
	c := Context{Family: S.HeadingFont, Bold: S.HeadingBold, Italic: S.HeadingItalic,
		Size: S.HSize[l], Leading: S.HLeading[l], Left: ctx.Left, Measure: ctx.Measure,
		Align: S.HeadingAlign, Hyphenate: ctx.Hyphenate}
	rec := HeadingRec{Level: h.Level, Star: h.Star, Plain: h.Plain}
	us := h.Text
	if !h.Star && S.HeadingNumber {
		w.counters[l]++
		for m := l + 1; m < 4; m++ {
			w.counters[m] = 0
		}
		num := strconv.Itoa(w.counters[0])
		for m := 1; m <= l; m++ {
			num += "." + strconv.Itoa(w.counters[m])
		}
		rec.Number = num
		pre := make([]markup.Unit, 0, len(num)+1+len(us))
		for _, r := range num {
			pre = append(pre, markup.Unit{Kind: markup.UChar, R: r})
		}
		pre = append(pre, markup.Unit{Kind: markup.UFixed, Aux: S.HeadingNumberGap})
		us = append(pre, us...)
	}
	if h.Level == 1 && S.H1Newpage {
		w.push(VItem{Kind: VForce})
		w.pm, w.pa = 0, 0
	}
	w.leaf(S.HSpaceBefore[l], S.HSpaceAfter[l], func() {
		rec.Item = len(w.items)
		w.emitLines(e.BreakAndSet(e.BuildList(us, c)), true)
	})
	w.headings = append(w.headings, rec)
}

func (w *walker) list(l *markup.List, ctx Context, depth int) {
	e, S := w.e, w.e.S
	w.pm = max64(w.pm, S.ListSpace)
	c := ctx
	c.Left += S.ListIndent
	c.Measure = clampMeasure(c.Measure - S.ListIndent)
	for idx, it := range l.Items {
		if idx > 0 {
			w.pm = max64(w.pm, S.ListItemSpace)
		}
		w.leaf(0, 0, func() {
			start := len(w.items)
			w.emitLines(e.BreakAndSet(e.BuildList(it.Text, c)), false)
			first := w.items[start].Line
			text := marker(l, depth, idx)
			face := metrics.FaceIndex(c.Family, false, false)
			wd := e.textWidth(face, c.Size, []rune(text))
			first.Extra = append(first.Extra, Run{Text: text, Face: face, Size: c.Size,
				X: c.Left - S.ListMarkerGap - wd, W: wd})
		})
		w.blocks(it.Children, c, depth)
	}
	w.pm = max64(w.pm, S.ListSpace)
}

// marker returns the marker text of item idx of a list at the given depth.
func marker(l *markup.List, depth, idx int) string {
	n := l.Start + idx
	switch depth % 3 {
	case 1:
		if !l.Ordered {
			return "•"
		}
		return strconv.Itoa(n) + "."
	case 2:
		if !l.Ordered {
			return "–"
		}
		return units.Letters(n) + "."
	}
	if !l.Ordered {
		return "*"
	}
	return units.Roman(n) + "."
}
