package layout

import (
	"typeset/dim"
	"typeset/hlist"
)

// rawPage is a page before headers and footers are added.
type rawPage struct {
	items   []PlacedItem
	chapter string // the current @h1 text for {chapter}
	section string // the current @h2 text for {section}
}

type paginator struct {
	lo               *layouter
	items            []vitem
	legal            []bool
	body             bool // the body (floats and footnotes apply); false for the TOC
	queue            []*figure
	carry            []*noteGroup
	pages            []rawPage
	chapter, section string
}

func newPaginator(lo *layouter, items []vitem, body bool) *paginator {
	p := &paginator{lo: lo, items: items, body: body}
	p.legal = computeLegal(items, int(lo.s.Widows), int(lo.s.Orphans), lo.s.KeepWithNext)
	return p
}

// computeLegal marks, for every position j in 0..n, whether a page break
// before item j is legal.
func computeLegal(items []vitem, widows, orphans int, keep bool) []bool {
	n := len(items)
	legal := make([]bool, n+1)
	for j := 1; j <= n; j++ {
		legal[j] = true
	}
	for j := 1; j < n; j++ {
		it := &items[j]
		if it.kind != vLine {
			continue
		}
		if it.heading {
			if it.k != 1 {
				legal[j] = false
			}
		} else if it.k > 1 {
			if !(it.k-1 >= orphans && it.n-it.k+1 >= widows) {
				legal[j] = false
			}
		}
	}
	if keep {
		for e := 0; e < n; e++ {
			it := &items[e]
			if it.kind != vLine || !it.heading || it.k != it.n {
				continue
			}
			t := e + 1
			for t < n && (items[t].kind == vGlue || items[t].kind == vFloat) {
				legal[t] = false
				t++
			}
			if t < n {
				legal[t] = false
				if x := &items[t]; x.kind == vLine {
					m := orphans
					if x.n < m {
						m = x.n
					}
					for q := t + 1; q <= t+m-1 && q < n; q++ {
						legal[q] = false
					}
				}
			}
		}
	}
	return legal
}

// noteStack computes the height of a stack of footnote groups.
type noteStack struct {
	st     vstate
	groups int
}

func (ns *noteStack) startGroup(itemSpace int64) {
	if ns.groups > 0 {
		ns.st.skip(itemSpace)
	} else {
		ns.st = newVstate(0)
	}
	ns.groups++
}

func (p *paginator) addNoteLine(ns *noteStack, ln *hlist.Line) int64 {
	return ns.st.line(p.lo.s.FootnoteLeading, p.lo.s.LineSkip, ln.Ascent, ln.Depth)
}

// area returns A_fn for the stack.
func (p *paginator) area(ns *noteStack) int64 {
	if ns.groups == 0 {
		return 0
	}
	s := p.lo.s
	return s.FootnoteSpaceBefore + s.FootnoteRuleThickness + s.FootnoteSpaceAfter + ns.st.cursor
}

func (p *paginator) run() []rawPage {
	lo, s := p.lo, p.lo.s
	n := len(p.items)
	i := 0
	for {
		for i < n && (p.items[i].kind == vGlue || p.items[i].kind == vForce) {
			i++
		}
		if i == n && len(p.queue) == 0 && len(p.carry) == 0 {
			break
		}
		pg := rawPage{}

		// Step 1: floats.
		bodyLeft := i < n
		k := 0
		var zone int64
		for k < len(p.queue) {
			z := zone + p.queue[k].block + s.FloatSpaceAfter
			ok := (bodyLeft && lo.bodyH-z >= s.FloatMinBody) ||
				(!bodyLeft && k == 0) || (!bodyLeft && z <= lo.bodyH)
			if !ok {
				break
			}
			zone = z
			k++
		}
		bodyTop := lo.bodyY + zone
		goal := lo.bodyH - zone
		y := lo.bodyY
		for _, f := range p.queue[:k] {
			pg.items = append(pg.items, lo.figureItems(f, y)...)
			y += f.block + s.FloatSpaceAfter
		}
		p.queue = p.queue[k:]

		// Steps 2-3: choose the cut.
		cut := n
		if i < n {
			cut = p.chooseCut(i, goal)
		}

		// Step 4: place the body.
		end := cut
		for end > i && p.items[end-1].kind == vGlue {
			end--
		}
		bodyEmpty := end == i
		st := newVstate(bodyTop)
		var groups []*noteGroup
		groups = append(groups, p.carry...)
		for j := i; j < end; j++ {
			it := &p.items[j]
			switch it.kind {
			case vLine:
				base := st.line(it.leading, s.LineSkip, it.line.Ascent, it.line.Depth)
				p.placeLine(&pg, it, base)
				for _, num := range it.line.Notes {
					groups = append(groups, &noteGroup{note: num, lines: lo.notes[num-1], mark: true})
				}
			case vGlue:
				st.skip(it.h)
			case vRule:
				pg.items = append(pg.items, PlacedItem{Region: RegionBody, Kind: ItemRule, X: it.x, Y: st.cursor, W: it.w, H: it.h})
				st.skip(it.h)
			case vRow:
				lo.rowItems(&pg, it, st.cursor)
				st.skip(it.h)
			}
		}
		B := st.cursor - bodyTop

		// Step 5: footnotes.
		var tail []*noteGroup
		if len(groups) > 0 {
			var placed []*noteGroup
			placed, tail = p.splitNotes(groups, goal-B, bodyEmpty)
			p.placeNotes(&pg, placed)
		}
		p.carry = tail

		// Step 6: queue the figures referenced on this page.
		if p.body {
			for j := i; j < cut; j++ {
				if p.items[j].kind == vFloat {
					p.queue = append(p.queue, lo.figures[p.items[j].fig])
				}
			}
		}
		pg.chapter, pg.section = p.chapter, p.section
		p.pages = append(p.pages, pg)
		i = cut
	}
	return p.pages
}

// chooseCut implements step 2 of page breaking.
func (p *paginator) chooseCut(i int, goal int64) int {
	lo, s := p.lo, p.lo.s
	n := len(p.items)
	st := newVstate(0)
	var trail int64
	var ns noteStack
	for _, g := range p.carry {
		ns.startGroup(s.FootnoteItemSpace)
		for _, ln := range g.lines {
			p.addNoteLine(&ns, ln)
		}
	}
	best := -1
	for j := i + 1; j <= n; j++ {
		it := &p.items[j-1]
		if it.kind == vForce {
			return j - 1
		}
		switch it.kind {
		case vLine:
			st.line(it.leading, s.LineSkip, it.line.Ascent, it.line.Depth)
			trail = 0
			for _, num := range it.line.Notes {
				ns.startGroup(s.FootnoteItemSpace)
				for _, ln := range lo.notes[num-1] {
					p.addNoteLine(&ns, ln)
				}
			}
		case vGlue:
			st.skip(it.h)
			trail += it.h
		case vRule, vRow:
			st.skip(it.h)
			trail = 0
		case vFloat:
			trail = 0
		}
		used := st.cursor - trail + dim.Min(p.area(&ns), s.FootnoteMaxHeight)
		if used > goal {
			break
		}
		if p.legal[j] {
			best = j
		}
		if j == n {
			break
		}
	}
	if best >= 0 {
		return best
	}
	for j := i + 1; j < n; j++ {
		if p.legal[j] {
			return j
		}
	}
	return n
}

// splitNotes performs step 5: it returns the groups placed on the page and
// the groups carried to the next page.
func (p *paginator) splitNotes(groups []*noteGroup, room int64, bodyEmpty bool) (placed, tail []*noteGroup) {
	s := p.lo.s
	avail := room - s.FootnoteSpaceBefore - s.FootnoteRuleThickness - s.FootnoteSpaceAfter
	var ns noteStack
	m := 0     // lines in the longest prefix that fits
	total := 0 // all candidate lines
	// groupEnd[g] is the number of lines up to and including group g.
	for _, g := range groups {
		total += len(g.lines)
	}
	fits := true
	count := 0
	for _, g := range groups {
		ns.startGroup(s.FootnoteItemSpace)
		for _, ln := range g.lines {
			p.addNoteLine(&ns, ln)
			count++
			if fits && ns.st.cursor <= avail {
				m = count
			} else {
				fits = false
			}
		}
	}
	// Min-split: the prefix ends strictly inside a group?
	if m > 0 && m < total {
		off := 0
		for _, g := range groups {
			if m < off+len(g.lines) {
				inGroup := m - off
				if inGroup > 0 && int64(inGroup) < s.FootnoteMinSplit && off > 0 {
					m = off
				}
				break
			}
			off += len(g.lines)
		}
	}
	if bodyEmpty && m == 0 && total > 0 {
		m = 1
	}
	off := 0
	for _, g := range groups {
		switch {
		case off+len(g.lines) <= m:
			placed = append(placed, g)
		case off >= m:
			tail = append(tail, g)
		default:
			c := m - off
			placed = append(placed, &noteGroup{note: g.note, lines: g.lines[:c], mark: g.mark})
			tail = append(tail, &noteGroup{note: g.note, lines: g.lines[c:], mark: false})
		}
		off += len(g.lines)
	}
	for _, g := range tail {
		p.lo.stats.FootnoteSplitLines += len(g.lines)
	}
	return placed, tail
}
