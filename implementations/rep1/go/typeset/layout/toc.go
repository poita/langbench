package layout

import (
	"typeset/codexa"
	"typeset/hlist"
)

// buildTOC builds the table of contents' vertical list from the headings
// placed by the body pagination.
func (lo *layouter) buildTOC() []vitem {
	s := lo.s
	vb := &vbuilder{}

	title := s.TocTitle
	if lo.doc.TOC.HasTitle {
		title = lo.doc.TOC.Title
	}
	tb := hlist.NewBuilder(lo.env, hlist.Context{
		Style: style(s.TocTitleFont, s.HeadingBold, s.HeadingItalic), Size: s.TocTitleSize,
		Align: hlist.ParseAlign(s.HeadingAlign), Hyphenate: s.Hyphenate,
	})
	tb.Inline(codexa.Literal(title))
	lines := lo.breakAndSet(tb.List(), hlist.Geometry{Left: lo.bodyX, Measure: lo.bodyW})
	vb.leaf(0, s.TocTitleSpaceAfter, lineItems(lines, s.HLeading[0], false))

	face := lo.faces.Face(style(s.TocFont, false, false))
	unit := face.StringWidth(s.TocLeader, s.TocSize)
	for _, h := range lo.headings {
		if h.star || int64(h.level) > s.TocDepth {
			continue
		}
		left := lo.bodyX + int64(h.level-1)*s.TocIndent
		measure := lo.bodyW - int64(h.level-1)*s.TocIndent - s.TocReserve
		b := hlist.NewBuilder(lo.env, hlist.Context{
			Style: style(s.TocFont, false, false), Size: s.TocSize,
			Align: hlist.Left, Hyphenate: s.Hyphenate,
		})
		if h.number != "" {
			b.Box(h.number, face, s.TocSize)
			b.Rigid(s.TocNumberGap)
		}
		b.Inline(codexa.Literal(h.plain))
		lines := lo.breakAndSet(b.List(), hlist.Geometry{Left: left, Measure: measure})
		items := lineItems(lines, s.TocLeading, false)

		last := lines[len(lines)-1]
		label := lo.pageLabel(h.page)
		lw := face.StringWidth(label, s.TocSize)
		labelX := lo.bodyX + lo.bodyW - lw
		xFrom := last.End() + s.TocLeaderGap
		xTo := labelX - s.TocLeaderGap
		var extras []hlist.Run
		if k := (xTo - xFrom) / unit; xTo-xFrom >= unit {
			text := ""
			for i := int64(0); i < k; i++ {
				text += s.TocLeader
			}
			extras = append(extras, hlist.Run{Face: face, Size: s.TocSize, X: xTo - k*unit, Width: k * unit, Text: text})
		}
		extras = append(extras, hlist.Run{Face: face, Size: s.TocSize, X: labelX, Width: lw, Text: label})
		items[len(items)-1].extras = extras
		vb.leaf(s.TocEntrySpace, s.TocEntrySpace, items)
	}
	return vb.items
}
