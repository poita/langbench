package layout

import (
	"strconv"

	"typeset/markup"
	"typeset/units"
)

// FigBlock is a laid-out figure, with everything relative to its top.
type FigBlock struct {
	H     int64 // block height
	Frame bool
	FX    int64
	FW    int64
	FH    int64
	Lines []*Line
	Offs  []int64 // baseline offsets from the block top
}

// layoutFigure lays out figure number n (1-based) once and stores it.
func (e *Env) layoutFigure(f *markup.Figure, n int) {
	S := e.S
	fw := S.FigureWidth
	if f.HasWidth {
		fw = f.Width
	}
	if fw <= 0 {
		fw = S.BodyWidth()
	}
	fx := S.BodyX() + units.FloorDiv(S.BodyWidth()-fw, 2)
	var us []markup.Unit
	if S.FigureCaptionPrefix != "" {
		us = append(us, markup.PlainUnits(S.FigureCaptionPrefix)...)
		us = append(us, markup.Unit{Kind: markup.UGlue, Aux: 1})
	}
	for _, r := range strconv.Itoa(n) + "." {
		us = append(us, markup.Unit{Kind: markup.UChar, R: r})
	}
	us = append(us, markup.Unit{Kind: markup.UFixed, Aux: S.FigureCaptionGap})
	us = append(us, f.Caption...)
	ctx := Context{Family: S.FigureCaptionFont, Size: S.FigureCaptionSize, Leading: S.FigureCaptionLeading,
		Left: fx, Measure: clampMeasure(fw), Align: S.FigureCaptionAlign, Hyphenate: S.Hyphenate}
	lines := e.BreakAndSet(e.BuildList(us, ctx))
	fb := &FigBlock{Frame: S.FigureFrame, FX: fx, FW: fw, FH: f.Height, Lines: lines}
	y := f.Height + S.FigureCaptionSpace
	var prevBase, prevDepth int64
	for i, ln := range lines {
		if i == 0 {
			y += ln.Ascent
		} else {
			y = prevBase + max64(ln.Leading, prevDepth+S.LineSkip+ln.Ascent)
		}
		fb.Offs = append(fb.Offs, y)
		prevBase, prevDepth = y, ln.Depth
	}
	fb.H = prevBase + prevDepth
	e.figs = append(e.figs, fb)
}

// layoutFootnotes breaks every footnote into its lines, once.
func (e *Env) layoutFootnotes() {
	S := e.S
	ctx := Context{Family: S.FootnoteFont, Size: S.FootnoteSize, Leading: S.FootnoteLeading,
		Left: S.BodyX() + S.FootnoteIndent, Measure: clampMeasure(S.BodyWidth() - S.FootnoteIndent),
		Align: S.Align, Hyphenate: S.Hyphenate}
	for _, us := range e.Doc.Footnotes {
		e.fnLines = append(e.fnLines, e.BreakAndSet(e.BuildList(us, ctx)))
	}
}
