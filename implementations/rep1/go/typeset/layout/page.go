package layout

import (
	"typeset/metrics"
)

// Regions of a page, in output order.
const (
	RHeader = iota
	RFloat
	RBody
	RFootnote
	RFooter
)

// Kinds of output item, in output order.
const (
	KText = iota
	KRule
	KBox
)

// OutItem is one placed item of a page. For text items Y is the baseline;
// for rules and boxes it is the top edge.
type OutItem struct {
	Region, Kind uint8
	Face         int
	Size         int64
	X, Y, W, H   int64
	Text         string
}

// Page is one output page.
type Page struct {
	Label string
	Num   int // numeric value of the label (for even/odd selection)
	Items []OutItem
}

type pageRec struct {
	page       *Page
	first, cut int
}

type fnGroup struct {
	lines []*Line
	num   int32
	mark  bool
}

func emitLine(out *[]OutItem, region uint8, ln *Line, baseline int64) {
	for _, r := range ln.Runs {
		*out = append(*out, OutItem{Region: region, Kind: KText, Face: r.Face, Size: r.Size,
			X: r.X, Y: baseline - r.Raise, W: r.W, Text: r.Text})
	}
	for _, r := range ln.Extra {
		*out = append(*out, OutItem{Region: region, Kind: KText, Face: r.Face, Size: r.Size,
			X: r.X, Y: baseline - r.Raise, W: r.W, Text: r.Text})
	}
}

// legality computes, for every position j (before item j), whether a page
// break is legal there.
func (e *Env) legality(items []VItem) []bool {
	S := e.S
	n := len(items)
	legal := make([]bool, n+1)
	for j := 1; j <= n; j++ {
		legal[j] = true
	}
	for j := 1; j < n; j++ {
		it := &items[j]
		if it.Kind != VLine {
			continue
		}
		if it.Heading {
			if it.K != 1 {
				legal[j] = false
			}
		} else if it.K > 1 {
			if int64(it.K-1) < S.Orphans || int64(it.N-it.K+1) < S.Widows {
				legal[j] = false
			}
		}
	}
	if S.KeepWithNext {
		for f := 0; f < n; f++ {
			it := &items[f]
			if it.Kind != VLine || !it.Heading || it.K != 1 {
				continue
			}
			l := f + int(it.N) - 1
			for j := f + 1; j <= l && j < n; j++ {
				legal[j] = false
			}
			k := l + 1
			for k < n && (items[k].Kind == VGlue || items[k].Kind == VFloat) {
				legal[k] = false
				k++
			}
			if k < n {
				legal[k] = false
			}
		}
	}
	if n == 0 {
		return legal
	}
	legal[0] = false
	return legal
}

type stackSim struct {
	cursor, prevBase, prevDepth int64
	fresh                       bool
	groups, lines               int
}

func newStack() stackSim { return stackSim{fresh: true} }

// add appends a group of footnote lines to the stack, recording the stack
// height after each line in cum when it is non-nil.
func (e *Env) stackAdd(s *stackSim, lines []*Line, cum *[]int64) {
	S := e.S
	if s.groups > 0 {
		s.cursor += S.FootnoteItemSpace
		s.fresh = true
	}
	s.groups++
	for _, ln := range lines {
		var base int64
		if s.fresh {
			base = s.cursor + ln.Ascent
		} else {
			base = s.prevBase + max64(S.FootnoteLeading, s.prevDepth+S.LineSkip+ln.Ascent)
		}
		s.cursor = base + ln.Depth
		s.prevBase, s.prevDepth = base, ln.Depth
		s.fresh = false
		s.lines++
		if cum != nil {
			*cum = append(*cum, s.cursor)
		}
	}
}

func (e *Env) fnArea(s *stackSim) int64 {
	if s.lines == 0 {
		return 0
	}
	S := e.S
	return S.FootnoteSpaceBefore + S.FootnoteRuleThick + S.FootnoteSpaceAfter + s.cursor
}

// paginate breaks a vertical list into pages.
func (e *Env) paginate(items []VItem) []*pageRec {
	S := e.S
	n := len(items)
	legal := e.legality(items)
	bodyH, bodyY := S.BodyHeight(), S.BodyY()
	var recs []*pageRec
	var queue []int32
	var carried []fnGroup
	i := 0
	for {
		for i < n && (items[i].Kind == VGlue || items[i].Kind == VForce) {
			i++
		}
		if i == n && len(queue) == 0 && len(carried) == 0 {
			break
		}
		pg := &Page{}
		// Step 1: figures.
		k, zone := 0, int64(0)
		for k < len(queue) {
			fb := e.figs[queue[k]]
			z1 := zone + fb.H + S.FloatSpaceAfter
			var take bool
			if i < n {
				take = bodyH-z1 >= S.FloatMinBody
			} else {
				take = k == 0 || z1 <= bodyH
			}
			if !take {
				break
			}
			zone = z1
			k++
		}
		taken := queue[:k]
		queue = queue[k:]
		bodyTop := bodyY + zone
		goal := bodyH - zone
		y := bodyY
		for _, fi := range taken {
			fb := e.figs[fi]
			if fb.Frame {
				pg.Items = append(pg.Items, OutItem{Region: RFloat, Kind: KBox, X: fb.FX, Y: y, W: fb.FW, H: fb.FH})
			}
			for li, ln := range fb.Lines {
				emitLine(&pg.Items, RFloat, ln, y+fb.Offs[li])
			}
			y += fb.H + S.FloatSpaceAfter
		}

		// Steps 2-3: choose the cut.
		cut := n
		if i < n {
			sim := newStack()
			for _, g := range carried {
				e.stackAdd(&sim, g.lines, nil)
			}
			var cursor, prevBase, prevDepth, usedNG int64
			fresh := true
			best, forced := -1, -1
			for j := i + 1; ; j++ {
				it := &items[j-1]
				if it.Kind == VForce {
					forced = j - 1
					break
				}
				switch it.Kind {
				case VLine:
					ln := it.Line
					var base int64
					if fresh {
						base = cursor + ln.Ascent
					} else {
						base = prevBase + max64(ln.Leading, prevDepth+S.LineSkip+ln.Ascent)
					}
					cursor = base + ln.Depth
					prevBase, prevDepth = base, ln.Depth
					fresh = false
					usedNG = cursor
					for _, fn := range ln.Fns {
						e.stackAdd(&sim, e.fnLines[fn-1], nil)
					}
				case VGlue:
					cursor += it.H
					fresh = true
				case VRule, VRow:
					cursor += it.H
					fresh = true
					usedNG = cursor
				case VFloat:
					usedNG = cursor
				}
				used := usedNG + min64(e.fnArea(&sim), S.FootnoteMaxHeight)
				if used <= goal && legal[j] {
					best = j
				}
				if used > goal || j == n {
					break
				}
			}
			switch {
			case forced >= 0:
				cut = forced
			case best >= 0:
				cut = best
			default:
				for j := i + 1; j <= n; j++ {
					if legal[j] {
						cut = j
						break
					}
				}
			}
		}

		// Step 4: place the body.
		end := cut
		for end > i && items[end-1].Kind == VGlue {
			end--
		}
		bodyEmpty := end == i
		cursor := bodyTop
		var prevBase, prevDepth int64
		fresh := true
		var refs []int32
		for _, it := range items[i:end] {
			switch it.Kind {
			case VLine:
				ln := it.Line
				var base int64
				if fresh {
					base = cursor + ln.Ascent
				} else {
					base = prevBase + max64(ln.Leading, prevDepth+S.LineSkip+ln.Ascent)
				}
				emitLine(&pg.Items, RBody, ln, base)
				cursor = base + ln.Depth
				prevBase, prevDepth = base, ln.Depth
				fresh = false
				refs = append(refs, ln.Fns...)
			case VGlue:
				cursor += it.H
				fresh = true
			case VRule:
				pg.Items = append(pg.Items, OutItem{Region: RBody, Kind: KRule, X: it.X, Y: cursor, W: it.W, H: it.H})
				cursor += it.H
				fresh = true
			case VRow:
				for _, cell := range it.Row {
					for _, rl := range cell {
						emitLine(&pg.Items, RBody, rl.Line, cursor+rl.Off)
					}
				}
				cursor += it.H
				fresh = true
			}
		}
		B := cursor - bodyTop

		// Step 5: footnotes.
		groups := append([]fnGroup(nil), carried...)
		for _, fn := range refs {
			groups = append(groups, fnGroup{lines: e.fnLines[fn-1], num: fn, mark: true})
		}
		var cum []int64
		var gstart []int // index of each line's group's first line
		var gidx []int
		{
			sim := newStack()
			pos := 0
			for gi, g := range groups {
				e.stackAdd(&sim, g.lines, &cum)
				for range g.lines {
					gidx = append(gidx, gi)
					gstart = append(gstart, pos)
				}
				pos += len(g.lines)
			}
		}
		M := len(cum)
		avail := goal - B - S.FootnoteSpaceBefore - S.FootnoteRuleThick - S.FootnoteSpaceAfter
		m := 0
		for m < M && cum[m] <= avail {
			m++
		}
		if m > 0 && m < M && gidx[m] == gidx[m-1] {
			if placed := m - gstart[m]; placed < int(S.FootnoteMinSplit) && gstart[m] > 0 {
				m = gstart[m]
			}
		}
		if bodyEmpty && M > 0 && m == 0 {
			m = 1
		}
		var next []fnGroup
		if m > 0 {
			hfn := cum[m-1]
			ruleTop := S.BodyBottom() - hfn - S.FootnoteSpaceAfter - S.FootnoteRuleThick
			pg.Items = append(pg.Items, OutItem{Region: RFootnote, Kind: KRule, X: S.BodyX(), Y: ruleTop,
				W: S.FootnoteRuleWidth, H: S.FootnoteRuleThick})
			cursor := ruleTop + S.FootnoteRuleThick + S.FootnoteSpaceAfter
			var prevBase, prevDepth int64
			fresh := true
			left := m
			for gi, g := range groups {
				if left <= 0 {
					next = append(next, groups[gi:]...)
					break
				}
				if gi > 0 {
					cursor += S.FootnoteItemSpace
					fresh = true
				}
				cnt := len(g.lines)
				if cnt > left {
					cnt = left
				}
				for li := 0; li < cnt; li++ {
					ln := g.lines[li]
					var base int64
					if fresh {
						base = cursor + ln.Ascent
					} else {
						base = prevBase + max64(S.FootnoteLeading, prevDepth+S.LineSkip+ln.Ascent)
					}
					emitLine(&pg.Items, RFootnote, ln, base)
					if li == 0 && g.mark {
						face := metrics.FaceIndex(S.FootnoteFont, false, false)
						txt := itoa(int64(g.num))
						wd := e.textWidth(face, S.FootnoteMarkSize, []rune(txt))
						pg.Items = append(pg.Items, OutItem{Region: RFootnote, Kind: KText, Face: face,
							Size: S.FootnoteMarkSize, X: S.BodyX() + S.FootnoteIndent - S.FootnoteMarkGap - wd,
							Y: base - S.FootnoteMarkRaise, W: wd, Text: txt})
					}
					cursor = base + ln.Depth
					prevBase, prevDepth = base, ln.Depth
					fresh = false
				}
				left -= cnt
				if cnt < len(g.lines) {
					next = append(next, fnGroup{lines: g.lines[cnt:], num: g.num, mark: false})
					next = append(next, groups[gi+1:]...)
					break
				}
			}
		} else {
			next = groups
		}
		e.Stats.FootnoteSplitLines += M - m
		carried = next

		// Step 6: queue the figures referenced on this page.
		for _, it := range items[i:cut] {
			if it.Kind == VFloat {
				queue = append(queue, it.Fig)
			}
		}
		recs = append(recs, &pageRec{page: pg, first: i, cut: cut})
		i = cut
	}
	return recs
}
