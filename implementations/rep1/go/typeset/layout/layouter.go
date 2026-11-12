package layout

import (
	"typeset/codexa"
	"typeset/dim"
	"typeset/hlist"
	"typeset/linebreak"
	"typeset/metric"
	"typeset/settings"
)

// layouter holds the state shared by all stages.
type layouter struct {
	s     *settings.Settings
	doc   *codexa.Document
	faces *metric.Set
	env   *hlist.Env
	lp    linebreak.Params
	stats Stats

	bodyX, bodyY, bodyW, bodyH, bodyBottom int64

	notes    [][]*hlist.Line // footnote lines, indexed by number-1
	figures  []*figure
	headings []*headInfo // all headings in document order
	counters [4]int
}

func newLayouter(in Input) *layouter {
	s := in.Settings
	lo := &layouter{s: s, doc: in.Doc, faces: in.Faces}
	lo.env = &hlist.Env{
		Faces: in.Faces, Patterns: in.Patterns, Hyphenate: s.Hyphenate,
		HyphenPenalty: s.HyphenPenalty, ExHyphenPenalty: s.ExHyphenPenalty,
		RaggedStretch: s.RaggedStretch, MarkSize: s.MarkSize, MarkRaise: s.MarkRaise,
	}
	lo.lp = linebreak.Params{
		Tolerance: s.Tolerance, LinePenalty: s.LinePenalty, AdjDemerits: s.AdjDemerits,
		DoubleHyphenDemerits: s.DoubleHyphenDemerits, FinalHyphenDemerits: s.FinalHyphenDemerits,
	}
	lo.bodyX, lo.bodyY, lo.bodyW, lo.bodyH, lo.bodyBottom =
		s.BodyX(), s.BodyY(), s.BodyWidth(), s.BodyHeight(), s.BodyBottom()
	return lo
}

func style(family string, bold, italic bool) metric.Style {
	return metric.Style{Family: metric.Family(family), Bold: bold, Italic: italic}
}

// breakAndSet breaks a list into lines and sets them, updating the counters.
func (lo *layouter) breakAndSet(l *hlist.List, geo hlist.Geometry) []*hlist.Line {
	r := linebreak.Break(l, geo.Measure, geo.FirstIndent, lo.lp)
	lo.stats.TotalDemerits += r.Total
	if r.Emergency {
		lo.stats.EmergencyLists++
	}
	return lo.setLines(l, r.Breaks, geo)
}

// setLines sets lines at the given breaks and counts them.
func (lo *layouter) setLines(l *hlist.List, breaks []int, geo hlist.Geometry) []*hlist.Line {
	lines := hlist.SetLines(lo.env, l, breaks, geo)
	for _, ln := range lines {
		lo.stats.Lines++
		if ln.Overfull {
			lo.stats.OverfullLines++
		}
		if ln.Hyphenated {
			lo.stats.HyphenatedLines++
		}
	}
	return lines
}

func clampMeasure(m int64) int64 {
	if m < 1000 {
		return 1000
	}
	return m
}

// lineItems converts set lines into vertical items of one group.
func lineItems(lines []*hlist.Line, leading int64, heading bool) []vitem {
	out := make([]vitem, len(lines))
	for i, ln := range lines {
		out[i] = vitem{kind: vLine, line: ln, leading: leading, k: i + 1, n: len(lines), heading: heading}
	}
	return out
}

// vstate implements "Vertical placement on a page".
type vstate struct {
	cursor, prevBase, prevDepth int64
	fresh                       bool
}

func newVstate(top int64) vstate { return vstate{cursor: top, fresh: true} }

// line places a line and returns its baseline.
func (v *vstate) line(leading, lineSkip, ascent, depth int64) int64 {
	var base int64
	if v.fresh {
		base = v.cursor + ascent
	} else {
		base = v.prevBase + dim.Max(leading, v.prevDepth+lineSkip+ascent)
	}
	v.cursor = base + depth
	v.prevBase, v.prevDepth, v.fresh = base, depth, false
	return base
}

func (v *vstate) skip(h int64) {
	v.cursor += h
	v.fresh = true
}

// Layout lays out the document.
func Layout(in Input) *Result {
	lo := newLayouter(in)
	lo.buildNotes()
	body := lo.buildBody()
	bp := newPaginator(lo, body, true)
	bodyPages := bp.run()

	var front []rawPage
	if lo.doc.TOC != nil {
		toc := lo.buildTOC()
		tp := newPaginator(lo, toc, false)
		front = tp.run()
	}
	return lo.assemble(front, bodyPages)
}
