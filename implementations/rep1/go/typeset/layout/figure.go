package layout

import (
	"strconv"

	"typeset/codexa"
	"typeset/dim"
	"typeset/hlist"
)

// figure is a laid-out figure block. Its positions are relative to the
// block's top.
type figure struct {
	height   int64 // the figure's own height H
	fx, fw   int64
	lines    []*hlist.Line
	baseline []int64 // relative to the block top
	block    int64   // the block's height
}

// newFigure lays out a @fig block and returns its index.
func (lo *layouter) newFigure(f *codexa.Figure) int {
	s := lo.s
	idx := len(lo.figures)
	fw := f.Width
	if !f.HasWidth {
		fw = s.FigureWidth
	}
	if fw <= 0 {
		fw = lo.bodyW
	}
	fx := lo.bodyX + dim.FloorDiv(lo.bodyW-fw, 2)
	b := hlist.NewBuilder(lo.env, hlist.Context{
		Style: style(s.FigureCaptionFont, false, false), Size: s.FigureCaptionSize,
		Align: hlist.ParseAlign(s.FigureCaptionAlign), Hyphenate: s.Hyphenate,
	})
	if s.FigureCaptionPrefix != "" {
		b.Inline(codexa.Literal(s.FigureCaptionPrefix))
		b.Space()
	}
	b.Box(strconv.Itoa(idx+1)+".", b.Face(), s.FigureCaptionSize)
	b.Rigid(s.FigureCaptionGap)
	b.Inline(f.Caption)
	lines := lo.breakAndSet(b.List(), hlist.Geometry{Left: fx, Measure: fw})

	fig := &figure{height: f.Height, fx: fx, fw: fw, lines: lines}
	st := newVstate(f.Height + s.FigureCaptionSpace)
	for _, ln := range lines {
		fig.baseline = append(fig.baseline, st.line(s.FigureCaptionLeading, s.LineSkip, ln.Ascent, ln.Depth))
	}
	fig.block = st.cursor
	lo.figures = append(lo.figures, fig)
	return idx
}
