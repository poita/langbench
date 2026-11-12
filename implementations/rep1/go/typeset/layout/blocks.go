package layout

import (
	"strconv"

	"typeset/codexa"
	"typeset/dim"
	"typeset/hlist"
	"typeset/numeral"
)

// vbuilder builds a vertical list with the pending-space registers.
type vbuilder struct {
	items      []vitem
	pendingMax int64
	pendingAdd int64
	started    bool
}

func (v *vbuilder) enter(before int64) { v.pendingMax = dim.Max(v.pendingMax, before) }
func (v *vbuilder) leave(after int64)  { v.pendingMax = dim.Max(v.pendingMax, after) }

func (v *vbuilder) vspace(h int64) { v.pendingAdd += h }

func (v *vbuilder) force() {
	v.items = append(v.items, vitem{kind: vForce})
	v.pendingMax, v.pendingAdd = 0, 0
}

// leaf emits a leaf block's items with the space rules applied.
func (v *vbuilder) leaf(before, after int64, items []vitem) {
	v.pendingMax = dim.Max(v.pendingMax, before)
	if v.started && v.pendingMax+v.pendingAdd > 0 {
		v.items = append(v.items, vitem{kind: vGlue, h: v.pendingMax + v.pendingAdd})
	}
	v.pendingMax, v.pendingAdd = after, 0
	v.items = append(v.items, items...)
	v.started = true
}

// bctx is the block context during the tree walk.
type bctx struct {
	family    string
	size      int64
	leading   int64
	align     string
	left      int64
	measure   int64
	hyphenate bool
}

// walker walks the block tree.
type walker struct {
	lo    *layouter
	vb    *vbuilder
	depth int // enclosing lists
}

// buildNotes breaks every footnote once.
func (lo *layouter) buildNotes() {
	s := lo.s
	lo.notes = make([][]*hlist.Line, len(lo.doc.Footnotes))
	geo := hlist.Geometry{Left: lo.bodyX + s.FootnoteIndent, Measure: lo.bodyW - s.FootnoteIndent}
	for i, fn := range lo.doc.Footnotes {
		b := hlist.NewBuilder(lo.env, hlist.Context{
			Style: style(s.FootnoteFont, false, false), Size: s.FootnoteSize,
			Align: hlist.ParseAlign(s.Align), Hyphenate: s.Hyphenate,
		})
		b.Inline(fn.Text)
		lo.notes[i] = lo.breakAndSet(b.List(), geo)
		lo.stats.Footnotes++
	}
}

// buildBody walks the document and returns the body's vertical list.
func (lo *layouter) buildBody() []vitem {
	s := lo.s
	w := &walker{lo: lo, vb: &vbuilder{}}
	root := bctx{
		family: s.BodyFont, size: s.BodySize, leading: s.Leading, align: s.Align,
		left: lo.bodyX, measure: lo.bodyW, hyphenate: s.Hyphenate,
	}
	w.blocks(lo.doc.Blocks, root)
	return w.vb.items
}

func (w *walker) blocks(bs []codexa.Block, c bctx) {
	for _, b := range bs {
		w.block(b, c)
	}
}

func (w *walker) hctx(c bctx, bold, italic bool) hlist.Context {
	return hlist.Context{
		Style: style(c.family, bold, italic), Size: c.size,
		Align: hlist.ParseAlign(c.align), Hyphenate: c.hyphenate,
	}
}

func (w *walker) block(b codexa.Block, c bctx) {
	lo, s, vb := w.lo, w.lo.s, w.vb
	switch b := b.(type) {
	case *codexa.Paragraph:
		lo.stats.Paragraphs++
		bl := hlist.NewBuilder(lo.env, w.hctx(c, false, false))
		bl.Inline(b.Text)
		lines := lo.breakAndSet(bl.List(), hlist.Geometry{Left: c.left, Measure: c.measure, FirstIndent: s.ParIndent})
		vb.leaf(s.ParSpace, s.ParSpace, lineItems(lines, c.leading, false))
	case *codexa.Heading:
		w.heading(b, c)
	case *codexa.Quote:
		vb.enter(s.QuoteSpace)
		c2 := c
		c2.left += s.QuoteIndent
		c2.measure = clampMeasure(c.measure - 2*s.QuoteIndent)
		w.blocks(b.Children, c2)
		vb.leave(s.QuoteSpace)
	case *codexa.Group:
		c2 := c
		if b.HasAlign {
			c2.align = b.Align
		}
		if b.HasSize {
			c2.size = b.Size
		}
		if b.HasLeading {
			c2.leading = b.Leading
		}
		if b.HasFont {
			c2.family = b.Font
		}
		c2.left += b.Indent
		c2.measure = clampMeasure(c.measure - b.Indent - b.RightIndent)
		w.blocks(b.Children, c2)
	case *codexa.List:
		w.list(b, c)
	case *codexa.Table:
		lo.stats.Tables++
		vb.leaf(s.TableSpace, s.TableSpace, lo.table(b, c))
	case *codexa.Pre:
		w.pre(b, c)
	case *codexa.Figure:
		lo.stats.Figures++
		idx := lo.newFigure(b)
		vb.leaf(0, 0, []vitem{{kind: vFloat, fig: idx}})
	case *codexa.Rule:
		vb.leaf(s.RuleSpace, s.RuleSpace, []vitem{{kind: vRule, x: c.left, w: c.measure, h: s.RuleThickness}})
	case *codexa.VSpace:
		vb.vspace(b.Height)
	case *codexa.NewPage:
		vb.force()
	}
}

func (w *walker) heading(h *codexa.Heading, c bctx) {
	lo, s := w.lo, w.lo.s
	lo.stats.Headings++
	lv := h.Level - 1
	size := s.HSize[lv]
	ctx := hlist.Context{
		Style: style(s.HeadingFont, s.HeadingBold, s.HeadingItalic), Size: size,
		Align: hlist.ParseAlign(s.HeadingAlign), Hyphenate: c.hyphenate,
	}
	bl := hlist.NewBuilder(lo.env, ctx)
	info := &headInfo{level: h.Level, star: h.Star, plain: codexa.PlainText(h.Text)}
	if !h.Star && s.HeadingNumber {
		lo.counters[lv]++
		for m := lv + 1; m < 4; m++ {
			lo.counters[m] = 0
		}
		num := strconv.Itoa(lo.counters[0])
		for m := 1; m <= lv; m++ {
			num += "." + strconv.Itoa(lo.counters[m])
		}
		info.number = num
		bl.Box(num, bl.Face(), size)
		bl.Rigid(s.HeadingNumberGap)
	}
	bl.Inline(h.Text)
	lo.headings = append(lo.headings, info)
	lines := lo.breakAndSet(bl.List(), hlist.Geometry{Left: c.left, Measure: c.measure})
	items := lineItems(lines, s.HLeading[lv], true)
	items[0].head = info
	if h.Level == 1 && s.H1Newpage {
		w.vb.force()
	}
	w.vb.leaf(s.HSpaceBefore[lv], s.HSpaceAfter[lv], items)
}

func (w *walker) pre(p *codexa.Pre, c bctx) {
	lo, s := w.lo, w.lo.s
	var items []vitem
	n := len(p.Lines)
	face := lo.faces.Face(style(s.PreFont, false, false))
	geo := hlist.Geometry{Left: c.left + s.PreIndent, Measure: clampMeasure(c.measure - s.PreIndent)}
	for i, text := range p.Lines {
		bl := hlist.NewBuilder(lo.env, hlist.Context{
			Style: style(s.PreFont, false, false), Size: s.PreSize, Align: hlist.Left,
		})
		if text != "" {
			bl.Box(text, face, s.PreSize)
		}
		l := bl.List()
		lines := lo.setLines(l, []int{l.Final()}, geo)
		items = append(items, vitem{kind: vLine, line: lines[0], leading: s.PreLeading, k: i + 1, n: n})
	}
	w.vb.leaf(s.PreSpace, s.PreSpace, items)
}

func markerText(ordered bool, depth, number int) string {
	switch depth % 3 {
	case 1:
		if ordered {
			return strconv.Itoa(number) + "."
		}
		return "•"
	case 2:
		if ordered {
			return numeral.Alpha(number) + "."
		}
		return "–"
	}
	if ordered {
		return numeral.Roman(number) + "."
	}
	return "*"
}

func (w *walker) list(l *codexa.List, c bctx) {
	lo, s, vb := w.lo, w.lo.s, w.vb
	vb.enter(s.ListSpace)
	c2 := c
	c2.left += s.ListIndent
	c2.measure = clampMeasure(c.measure - s.ListIndent)
	w.depth++
	face := lo.faces.Face(style(c2.family, false, false))
	for idx, it := range l.Items {
		if idx > 0 {
			vb.pendingMax = dim.Max(vb.pendingMax, s.ListItemSpace)
		}
		bl := hlist.NewBuilder(lo.env, w.hctx(c2, false, false))
		bl.Inline(it.Text)
		lines := lo.breakAndSet(bl.List(), hlist.Geometry{Left: c2.left, Measure: c2.measure})
		items := lineItems(lines, c2.leading, false)
		text := markerText(l.Ordered, w.depth, int(l.Start)+idx)
		mw := face.StringWidth(text, c2.size)
		items[0].extras = append(items[0].extras, hlist.Run{
			Face: face, Size: c2.size, X: c2.left - s.ListMarkerGap - mw, Width: mw, Text: text,
		})
		vb.leaf(0, 0, items)
		w.blocks(it.Children, c2)
	}
	w.depth--
	vb.leave(s.ListSpace)
}
